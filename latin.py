"""The name a station is known by internationally, in Latin script. First hit wins:

  1. `int_name`
  2. the local name, if it is in Latin script
  3. `name:<lang>-Latn` (or `name:ja_rm`), a mapper's romanisation
  4. `name:en`, if it is itself a romanisation of the local name
  5. BGN/PCGN transliteration, for scripts ICU romanises well (see TRANSLITERABLE)
  6. `name:en`, then the local name

`name:en` is often a translation ("Kazan Passenger Moscow"), hence 4 before 6. BGN rather
than ICU's generic Any-Latin because it gives the spellings timetables use.
"""

import difflib
import re
import unicodedata
from collections import Counter

import icu

# How close `name:en` must be to the transliteration to count as a romanisation of the
# local name rather than a translation.
ROMANISATION_SIMILARITY = 0.85

TRANSLITERABLE = frozenset({"Cyrl", "Grek", "Armn", "Geor"})

# Cyrillic romanisation depends on the language, hence by country. KZ, KG, TJ and MN have
# no BGN transform of their own and use the Russian one.
BGN_BY_COUNTRY = {
    "RU": "Russian", "KZ": "Russian", "KG": "Russian", "TJ": "Russian", "MN": "Russian",
    "UA": "Ukrainian", "BY": "Belarusian", "BG": "Bulgarian",
    "RS": "Serbian", "ME": "Serbian", "BA": "Serbian", "MK": "Macedonian",
}
BGN_BY_SCRIPT = {"Cyrl": "Russian", "Grek": "Greek", "Armn": "Armenian", "Geor": "Georgian"}

# Unicode character names begin with their script. Values are ICU short names.
SCRIPT_BY_NAME_PREFIX = {
    "LATIN": "Latn", "CYRILLIC": "Cyrl", "GREEK": "Grek", "ARMENIAN": "Armn",
    "GEORGIAN": "Geor", "HANGUL": "Hang", "HIRAGANA": "Hira", "KATAKANA": "Kana",
    "THAI": "Thai", "LAO": "Laoo", "KHMER": "Khmr", "MYANMAR": "Mymr", "ARABIC": "Arab",
    "HEBREW": "Hebr", "DEVANAGARI": "Deva", "BENGALI": "Beng", "TAMIL": "Taml",
    "ETHIOPIC": "Ethi", "TIBETAN": "Tibt",
}

# BGN renders soft and hard signs as primes, which no timetable uses.
PRIMES = str.maketrans("", "", "ʹʺ’ʼ'`")

_transliterators = {}


def script_of(ch):
    try:
        name = unicodedata.name(ch)
    except ValueError:
        return None
    if "IDEOGRAPH" in name:
        return "Hani"
    return SCRIPT_BY_NAME_PREFIX.get(name.split()[0])


def dominant_script(text):
    scripts = [s for s in (script_of(ch) for ch in text or "" if ch.isalpha()) if s]
    return Counter(scripts).most_common(1)[0][0] if scripts else None


def is_latin(text):
    return dominant_script(text) == "Latn"


def transliterate(text, country):
    """BGN/PCGN romanisation of `text`, or None for scripts ICU does not romanise usefully
    ('dong jing' for 東京)."""
    script = dominant_script(text)
    if script not in TRANSLITERABLE:
        return None
    # The country's transform only applies to its own script: Greek in Ukraine is not Ukrainian.
    language = BGN_BY_COUNTRY.get(country) if script == "Cyrl" else None
    transform_id = f"{language or BGN_BY_SCRIPT[script]}-Latin/BGN"
    if transform_id not in _transliterators:
        try:
            _transliterators[transform_id] = icu.Transliterator.createInstance(transform_id)
        except icu.ICUError:
            _transliterators[transform_id] = None
    transliterator = _transliterators[transform_id]
    if transliterator is None:
        return None
    result = transliterator.transliterate(text).translate(PRIMES)
    # Georgian has no case, so its transform yields 'tbilisi'.
    if script == "Geor":
        result = result.title()
    result = re.sub(r"\s+", " ", result).strip()
    if not result or not is_latin(result):
        return None
    return unicodedata.normalize("NFC", result)


def fold(text):
    return "".join(
        ch for ch in unicodedata.normalize("NFD", (text or "").lower())
        if unicodedata.category(ch) != "Mn"
    )


def latin_name(names, country):
    """The international Latin-script name from a station's `names` (OSM tag -> value)."""
    if names.get("int_name"):
        return names["int_name"]
    local = names.get("name") or ""
    if is_latin(local):
        return local
    for key, value in names.items():
        if key.endswith("-Latn") or key.endswith("_rm"):
            return value
    name_en = names.get("name:en")
    romanised = transliterate(local, country) if local else None
    if romanised:
        if name_en and difflib.SequenceMatcher(None, fold(name_en), fold(romanised)).ratio() \
                >= ROMANISATION_SIMILARITY:
            return name_en
        return romanised
    return name_en or local
