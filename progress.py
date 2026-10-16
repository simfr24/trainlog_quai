"""Live progress on a terminal, as docker pull shows it: a few lines redrawn in place, with
what must stay (finished steps, warnings) printed above them. Elsewhere (a log, CI) nothing
is redrawn: callers print a line per event instead. Used by regions.py and build.py."""

import os
import re
import shutil
import sys
import threading
import time

TTY = sys.stdout.isatty()
COLOUR = TTY and not os.environ.get("NO_COLOR")
SPINNER = "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏"
ESCAPES = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")


def style(text, code):
    return f"\x1b[{code}m{text}\x1b[0m" if COLOUR else text


def green(text): return style(text, "32")
def red(text): return style(text, "31")
def yellow(text): return style(text, "33")
def cyan(text): return style(text, "36")
def dim(text): return style(text, "2")
def bold(text): return style(text, "1")


def spinner():
    return cyan(SPINNER[int(time.monotonic() * 10) % len(SPINNER)])


def bar(fraction, width=28):
    """━━━━━━╸━━━━━, filled in colour; without a fraction, a dim one, for a step whose
    length is not known."""
    if fraction is None:
        return dim("━" * width) if COLOUR else " " * width
    filled = max(0.0, min(fraction, 1.0)) * width
    full = int(filled)
    head = "╸" if full < width and filled - full >= 0.5 else ""
    rest = width - full - len(head)
    if not COLOUR:
        return "[" + "=" * full + (">" if head else "") + " " * rest + "]"
    return style("━" * full + head, "35") + dim("━" * rest)


def duration(seconds):
    minutes, seconds = divmod(int(seconds), 60)
    hours, minutes = divmod(minutes, 60)
    if hours:
        return f"{hours}h{minutes:02d}m"
    return f"{minutes}m{seconds:02d}s" if minutes else f"{seconds}s"


def human(size):
    for unit in ("B", "K", "M", "G"):
        if size < 1024 or unit == "G":
            return f"{size:.0f}{unit}" if unit in ("B", "K") else f"{size:.1f}{unit}"
        size /= 1024


def fit(line, columns):
    """A line no wider than the terminal, as one wrapped would break the redraw: cut, then
    without its colours."""
    if len(ESCAPES.sub("", line)) < columns:
        return line
    return ESCAPES.sub("", line)[:columns - 1]


class Live:
    """Lines from `render` (a function returning them) redrawn ten times a second while in
    its `with`, below everything `log` printed."""

    def __init__(self, render):
        self.render = render
        self.messages = []
        self.lock = threading.Lock()
        self.drawn = 0
        self.stop = threading.Event()
        self.thread = threading.Thread(target=self.run, daemon=True)

    def log(self, line):
        if TTY:
            with self.lock:
                self.messages.append(line)
        else:
            print(ESCAPES.sub("", line), flush=True)

    def draw(self):
        size = shutil.get_terminal_size()
        lines = self.render()[-(size.lines - 1):]
        with self.lock:
            out = [f"\x1b[{self.drawn}F"] if self.drawn else []
            out += [f"\x1b[2K{fit(message, size.columns)}\n" for message in self.messages]
            out += [f"\x1b[2K{fit(line, size.columns)}\n" for line in lines]
            out.append("\x1b[J")
            self.messages.clear()
            self.drawn = len(lines)
        sys.stdout.write("".join(out))
        sys.stdout.flush()

    def run(self):
        while not self.stop.wait(0.1):
            self.draw()

    def __enter__(self):
        if TTY:
            sys.stdout.write("\x1b[?25l")
            self.thread.start()
        return self

    def __exit__(self, *exc):
        if TTY:
            self.stop.set()
            self.thread.join()
            self.draw()
            sys.stdout.write("\x1b[?25h")
            sys.stdout.flush()
