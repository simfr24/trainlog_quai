"""Fetches and filters Geofabrik extracts, all regions at once, a line each kept up to date
as docker pull does: a download is replaced only when Geofabrik has a newer one, kept only
if it matches its checksum, and filtered (osmium, stations.params) when it or the filter
changed. Run by make, with as many filters at once as make's -j allows.

    python3 regions.py [--download-only] europe/france europe/great-britain
"""

import hashlib
import os
import re
import shutil
import subprocess
import sys
import threading
import time
from email.utils import parsedate_to_datetime
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from progress import ESCAPES, TTY, Live, bar, bold, dim, duration, green, human, red, spinner, yellow

GEOFABRIK = "https://download.geofabrik.de"
DOWNLOADS = Path("downloads")
FILTERED = Path("filtered")
PARAMS = Path("stations.params")
# Downloads at once: more would not be faster, only less polite to Geofabrik.
DOWNLOAD_SLOTS = 3
CHUNK = 1 << 20
# osmium tags-filter's passes through its input, as its log names them as each starts.
PASSES = {
    "relations in relations": "nested relations",
    "nodes/ways in relations": "relation members",
    "nodes in ways": "way nodes",
    "Copying matching objects": "copying",
}


def make_jobs():
    """make's -j: its count, every core for a bare -j, one without."""
    flags = os.environ.get("MAKEFLAGS", "")
    if match := re.search(r"(?:^|\s)-j(\d*)(?:\s|$)", flags):
        return int(match[1]) if match[1] else os.cpu_count()
    return 1


class Region:
    """What a region is doing, for its line: its state, how far along (0 to 1, None when not
    known) and the rest to say."""

    ACTIVE = ("checking", "downloading", "verifying", "filtering")

    def __init__(self, name):
        self.name = name
        self.state, self.progress, self.detail = "waiting", None, ""

    def set(self, state, progress=None, detail=""):
        changed = state != self.state
        self.state, self.progress, self.detail = state, progress, detail
        if not TTY and changed:
            print(f"{self.name}: {state}{'  ' + detail if detail else ''}", flush=True)

    def line(self, width, columns):
        if self.state in self.ACTIVE:
            mark = spinner()
        elif self.state == "failed":
            mark = red("✘")
        elif self.state in ("waiting", "queued"):
            mark = dim("·")
        else:
            mark = green("✔")
        state = f"{self.state:<11}"
        state = red(state) if self.state == "failed" else dim(state) if mark == dim("·") else state
        start = f"{mark} {self.name:<{width}}  {state} "
        if self.progress is None:
            return start + self.detail
        # The bar takes what the rest leaves of the terminal's width, within reason.
        room = columns - len(ESCAPES.sub("", start + self.detail)) - 8
        return f"{start}{bar(self.progress, max(10, min(room, 28)))} {self.progress:4.0%}  {self.detail}"


def head(url):
    """Size, date and final URL of the extract: Geofabrik may redirect to a mirror, whose
    file is named after its date."""
    with urlopen(Request(url, method="HEAD"), timeout=60) as response:
        return (int(response.headers["Content-Length"]), response.headers["Last-Modified"],
                response.url)


def download(region, url, path, last_modified):
    """Into a .part file, which an interrupted run resumes, if Geofabrik still has the same
    extract (If-Range), then dated as Geofabrik dates it, as wget -N would."""
    part = path.with_name(path.name + ".part")
    start = part.stat().st_size if part.exists() else 0
    request = Request(url)
    if start:
        request.add_header("Range", f"bytes={start}-")
        request.add_header("If-Range", last_modified)
    with urlopen(request, timeout=60) as response:
        if response.status != 206:
            start = 0
        total = start + int(response.headers["Content-Length"])
        done, rate, then = start, None, time.monotonic()
        with open(part, "ab" if start else "wb") as out:
            while chunk := response.read(CHUNK):
                out.write(chunk)
                done += len(chunk)
                # The rate over the last seconds rather than since the start, steadier than
                # a chunk's own.
                now = time.monotonic()
                instant = len(chunk) / max(now - then, 1e-3)
                rate = instant if rate is None else rate + (instant - rate) * min((now - then) / 3, 1)
                then = now
                left = (total - done) / rate if rate else 0
                region.set("downloading", done / total,
                           f"{human(done)}/{human(total)}  {human(rate)}/s  {dim(duration(left) + ' left')}")
    modified = parsedate_to_datetime(last_modified).timestamp()
    os.utime(part, (modified, modified))
    part.replace(path)


def md5(region, path):
    digest, size, done = hashlib.md5(), path.stat().st_size, 0
    with open(path, "rb") as f:
        while chunk := f.read(8 * CHUNK):
            digest.update(chunk)
            done += len(chunk)
            region.set("verifying", done / size, human(size))
    return digest.hexdigest()


def checksum(url, mirror):
    """Geofabrik serves each checksum either itself or only from the mirror."""
    for source in (url, mirror):
        try:
            with urlopen(source + ".md5", timeout=60) as response:
                return response.read().decode().split()[0]
        except HTTPError:
            if source == mirror:
                raise


def fetch(live, region):
    url = f"{GEOFABRIK}/{region.name}-latest.osm.pbf"
    path = DOWNLOADS / f"{region.name}-latest.osm.pbf"
    path.parent.mkdir(parents=True, exist_ok=True)
    region.set("checking")
    size, last_modified, mirror = head(url)
    modified = parsedate_to_datetime(last_modified).timestamp()
    if not (path.exists() and path.stat().st_size == size and path.stat().st_mtime >= modified):
        download(region, url, path, last_modified)
    expected = checksum(url, mirror)
    # Hashing the world takes minutes: a passed check is kept, while the extract is the one
    # checked.
    verified = path.with_name(path.name + ".verified")
    if (verified.exists() and verified.read_text().strip() == expected
            and verified.stat().st_mtime > path.stat().st_mtime):
        return path
    if md5(region, path) != expected:
        live.log(yellow(f"{path.name} does not match its checksum, downloading it again"))
        path.unlink()
        download(region, url, path, last_modified)
        if md5(region, path) != expected:
            raise RuntimeError(f"{path.name} does not match its checksum")
    verified.write_text(expected + "\n")
    return path


def read_position(pid, path):
    """How far osmium has read its input, from /proc: a pass's progress."""
    try:
        for fd in os.listdir(f"/proc/{pid}/fd"):
            if os.readlink(f"/proc/{pid}/fd/{fd}") == str(path):
                with open(f"/proc/{pid}/fdinfo/{fd}") as info:
                    return int(re.search(r"^pos:\s*(\d+)", info.read(), re.M)[1])
    except (OSError, TypeError):
        pass
    return None


class Passes:
    """osmium's passes, from its log (-v) as it goes: one to copy what matched, after one for
    each kind of reference to follow, as the kinds of objects filtered on call for."""

    def __init__(self, stderr):
        self.total, self.current, self.name, self.log = 1, 0, "starting", []
        self.reading = threading.Thread(target=self.read, args=(stderr,), daemon=True)
        self.reading.start()

    def read(self, stderr):
        on = {}
        for line in stderr:
            line = line.decode(errors="replace").rstrip()
            self.log = (self.log + [line])[-20:]
            if match := re.search(r"on (nodes|ways|relations): (yes|no)", line):
                on[match[1]] = match[2] == "yes"
                self.total = 1 + 2 * on.get("relations", False) + on.get("ways", False)
            elif "add referenced objects: no" in line:
                self.total = 1
            for marker, name in PASSES.items():
                if marker in line:
                    self.current += 1
                    self.total = max(self.total, self.current)
                    self.name = name

    def errors(self):
        return "\n".join(line for line in self.log if not line.startswith("[")) or "\n".join(self.log[-3:])


def filter_region(region, source):
    """Written under a temporary name and renamed once complete, so that an interrupted
    filter never leaves what a later run would take for a finished one."""
    out = FILTERED / f"{region.name}.osm.pbf"
    if out.exists() and out.stat().st_mtime >= max(source.stat().st_mtime, PARAMS.stat().st_mtime):
        region.set("up to date", None, dim(human(out.stat().st_size)))
        return
    out.parent.mkdir(parents=True, exist_ok=True)
    tmp = out.with_name(out.name + ".tmp")
    source, size, began = source.resolve(), source.stat().st_size, time.monotonic()
    process = subprocess.Popen(
        ["osmium", "tags-filter", "-v", "--no-progress", f"--expressions={PARAMS}", str(source),
         "-f", "pbf", "-o", str(tmp), "--overwrite"],
        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    passes = Passes(process.stderr)
    while process.poll() is None:
        position = read_position(process.pid, source)
        within = position / size if position is not None and passes.current else 0
        region.set("filtering", (max(passes.current - 1, 0) + within) / passes.total,
                   (f"{passes.current}/{passes.total} {passes.name}" if passes.current else "starting")
                   + f"  {dim(duration(time.monotonic() - began))}")
        time.sleep(0.2)
    passes.reading.join()
    if process.returncode:
        raise RuntimeError(passes.errors() or f"osmium exited with {process.returncode}")
    tmp.replace(out)
    region.set("filtered", None,
               f"{human(out.stat().st_size)} {dim('in ' + duration(time.monotonic() - began))}")


def main():
    args = sys.argv[1:]
    download_only = "--download-only" in args
    names = [arg for arg in args if not arg.startswith("--")]
    if not names:
        sys.exit(__doc__)
    regions = [Region(name) for name in names]
    width = max(len(name) for name in names)
    download_slots = threading.Semaphore(DOWNLOAD_SLOTS)
    filter_slots = threading.Semaphore(make_jobs())
    began = time.monotonic()

    def finished():
        return [r for r in regions if r.state not in ("waiting", "queued", *Region.ACTIVE)]

    def render():
        done = len(finished())
        failed = sum(r.state == "failed" for r in regions)
        footer = f"{done}/{len(regions)} regions" + (red(f", {failed} failed") if failed else "")
        columns = shutil.get_terminal_size().columns
        return ([region.line(width, columns) for region in regions]
                + [dim(f"  {footer} · {duration(time.monotonic() - began)}")])

    live = Live(render)

    def run(region):
        try:
            with download_slots:
                source = fetch(live, region)
            if download_only:
                region.set("downloaded", None, dim(human(source.stat().st_size)))
                return
            region.set("queued")
            with filter_slots:
                filter_region(region, source)
        except Exception as error:
            message = str(error) or type(error).__name__
            region.set("failed", None, message.splitlines()[0])
            live.log(red(f"{region.name}: {message}"))

    workers = [threading.Thread(target=run, args=(region,), daemon=True) for region in regions]
    try:
        with live:
            for worker in workers:
                worker.start()
            for worker in workers:
                while worker.is_alive():
                    worker.join(0.2)
    except KeyboardInterrupt:
        sys.exit(130)
    failed = [r.name for r in regions if r.state == "failed"]
    if failed:
        sys.exit(red(f"failed: {' '.join(failed)}"))
    if not TTY:
        print(f"{len(regions)} regions ready in {duration(time.monotonic() - began)}")


if __name__ == "__main__":
    main()
