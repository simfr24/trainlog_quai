"""The name a station is known by internationally, in Latin script. First hit wins:

  1. `int_name`
  2. the local name, if it is in Latin script
  3. `name:<lang>-Latn` (or `name:ja_rm`), a mapper's romanisation
  4. `name:en`, if it is itself a romanisation of the local name
  5. BGN/PCGN transliteration, for scripts ICU romanises well (see TRANSLITERABLE), and
     Pinyin in China
  6. `name:en`
  7. a rougher romanisation (fallback_latin), then the local name

`name:en` is often a translation ("Kazan Passenger Moscow"), hence 4 before 6. BGN rather
than ICU's generic Any-Latin because it gives the spellings timetables use.
"""

import difflib
import re
import unicodedata
from collections import Counter

import icu
from pypinyin import lazy_pinyin

# How close `name:en` must be to the transliteration to count as a romanisation of the
# local name rather than a translation.
ROMANISATION_SIMILARITY = 0.85

TRANSLITERABLE = frozenset({"Cyrl", "Grek", "Armn", "Geor", "Hang"})

# Cyrillic romanisation depends on the language, hence by country. KZ, KG, TJ and MN have
# no BGN transform of their own and use the Russian one.
BGN_BY_COUNTRY = {
    "RU": "Russian", "KZ": "Russian", "KG": "Russian", "TJ": "Russian", "MN": "Russian",
    "UA": "Ukrainian", "BY": "Belarusian", "BG": "Bulgarian",
    "RS": "Serbian", "ME": "Serbian", "BA": "Serbian", "MK": "Macedonian",
}
BGN_BY_SCRIPT = {"Cyrl": "Russian", "Grek": "Greek", "Armn": "Armenian", "Geor": "Georgian",
                 "Hang": "Korean"}

HAN = re.compile(r"[㐀-䶿一-鿿豈-﫿]+")

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
    """Every letter Latin: "香港西九龍 Hong Kong West Kowloon", mostly Latin letters, is not, so
    that its Latin name is its name:en rather than itself."""
    # A letter of a script not known here (Mongolian's) is not Latin either.
    return {script_of(ch) for ch in text or "" if ch.isalpha()} == {"Latn"}


def icu_transform(transform_id, text):
    """`text` through an ICU transform, or None if ICU has no such transform."""
    if transform_id not in _transliterators:
        try:
            _transliterators[transform_id] = icu.Transliterator.createInstance(transform_id)
        except icu.ICUError:
            _transliterators[transform_id] = None
    transliterator = _transliterators[transform_id]
    return transliterator.transliterate(text) if transliterator else None


def latin_or_none(result):
    result = re.sub(r"\s+", " ", result or "").strip()
    if not result or not is_latin(result):
        return None
    return unicodedata.normalize("NFC", result)


def pinyin(text):
    """Hanyu Pinyin, each run of characters one word as Chinese railways write names
    (成都东 Chengdudong), kept apart from the Latin letters and digits around it."""
    text = unicodedata.normalize("NFKC", text)

    def word(match):
        before = " " if match.start() and text[match.start() - 1].isalnum() else ""
        after = " " if match.end() < len(text) and text[match.end()].isalnum() else ""
        return before + "".join(lazy_pinyin(match.group(), v_to_u=True)).capitalize() + after

    return latin_or_none(re.sub(r"(\w)\(", r"\1 (", HAN.sub(word, text)))


def transliterate(text, country):
    """BGN/PCGN romanisation of `text`, or Pinyin in China; None for scripts ICU does not
    romanise usefully ('dong jing' for 東京)."""
    script = dominant_script(text)
    # A name in two scripts, without the words of the other, unless Latin: "Улаанбаатар
    # ᠤᠯᠠᠭᠠᠨᠪᠠᠭᠠᠲᠤᠷ" is Улаанбаатар, "BRT 黄台电厂" keeps BRT.
    text = " ".join(word for word in text.split()
                    if all(script_of(ch) in (script, "Latn") for ch in word if ch.isalpha()))
    if script == "Hani" and country == "CN":
        return pinyin(text)
    if script not in TRANSLITERABLE:
        return None
    # The country's transform only applies to its own script: Greek in Ukraine is not Ukrainian.
    language = BGN_BY_COUNTRY.get(country) if script == "Cyrl" else None
    result = icu_transform(f"{language or BGN_BY_SCRIPT[script]}-Latin/BGN", text)
    if result is None:
        return None
    result = result.translate(PRIMES)
    # Georgian and Hangul have no case, so their transforms yield 'tbilisi'.
    if script in ("Geor", "Hang"):
        result = result.title()
    return latin_or_none(result)


def fallback_latin(text, country):
    """A romanisation where nothing better is mapped, so that no one is shown a script they
    may not read: Pinyin for Chinese characters outside China too (Taiwan's, Hong Kong's),
    ICU's generic one for other scripts. None for kanji in Japan, which neither reads."""
    if HAN.search(text):
        return None if country == "JP" else pinyin(text)
    return latin_or_none(icu_transform("Any-Latin", text))


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
    return name_en or fallback_latin(local, country) or local
