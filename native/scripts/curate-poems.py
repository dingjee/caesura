#!/usr/bin/env python3
"""Curates the offline daily-poem dataset for the native Caesura app.

Fetches public-domain English poems from PoetryDB (https://poetrydb.org) for a
curated author whitelist, filters them to short poems (2-14 lines), tags them
with season/month relevance keywords, and writes
native/Sources/CaesuraCore/Resources/poems/poems.en.json.

The runtime never talks to PoetryDB; the generated dataset is committed. The
poem texts are public domain; the curated dataset inherits PoetryDB's CC BY 4.0
license, so the attribution line below must stay (About tab + README).

Author birth/death anniversaries: PoetryDB's /author/<name>:abs/info endpoint
only exposes years ("born": "1830"), which cannot answer "historical today".
The AUTHOR_ANNIVERSARIES table below therefore carries the commonly cited
month-day (MM-DD) for the whitelist authors. Dates are used only for
preference weighting, never shown to the user; authors without a reliable
month-day simply never win the anniversary tier.

The script is idempotent: raw API responses are cached in
native/scripts/.poetrydb-cache/ (gitignored), so re-runs are offline. Use
--refetch to download fresh copies.

Usage:
  python3 native/scripts/curate-poems.py [--refetch] [--cap N] [--min-count N]
                                         [--sample N] [--inspect POEM_ID]
"""
import argparse
import json
import random
import re
import sys
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "native" / "Sources" / "CaesuraCore" / "Resources" / "poems" / "poems.en.json"
OVERRIDES = ROOT / "native" / "scripts" / "poem-overrides.json"
CACHE = ROOT / "native" / "scripts" / ".poetrydb-cache"

ATTRIBUTION = "Poetry data from PoetryDB (https://poetrydb.org), licensed under CC BY 4.0."
CATALOG_VERSION = 1
MIN_LINES = 2
MAX_LINES = 14
EXCERPT_LINES = 4

# Curated whitelist (plan section 4.3, adjusted to PoetryDB's actual author
# list). Keys must match PoetryDB author names exactly. Values are (born MM-DD
# or None, died MM-DD or None) from common citations; None = no reliable
# month-day, the author gets no anniversary tier.
AUTHOR_ANNIVERSARIES = {
    "Emily Dickinson": ("12-10", "05-15"),
    "William Shakespeare": ("04-23", "04-23"),  # birth traditional (baptized 04-26)
    "William Wordsworth": ("04-07", "04-23"),
    "John Keats": ("10-31", "02-23"),
    "Percy Bysshe Shelley": ("08-04", "07-08"),
    "William Blake": ("11-28", "08-12"),
    "Robert Burns": ("01-25", "07-21"),
    "George Gordon, Lord Byron": ("01-22", "04-19"),
    "Samuel Coleridge": ("10-21", "07-25"),
    "Christina Rossetti": ("12-05", "12-29"),
    "Elizabeth Barrett Browning": ("03-06", "06-29"),
    "Robert Browning": ("05-07", "12-12"),
    "Lord Alfred Tennyson": ("08-06", "10-06"),
    "Walt Whitman": ("05-31", "03-26"),
    "Emily Bronte": ("07-30", "12-19"),
    "Anne Bronte": ("01-17", "05-28"),
    "Charlotte Bronte": ("04-21", "03-31"),
    "Charlotte Smith": ("05-04", "10-28"),
    "Phillis Wheatley": (None, "12-05"),  # birth unknown (c. 1753)
    "Robert Louis Stevenson": ("11-13", "12-03"),
    "William Ernest Henley": ("08-23", "07-11"),
    "Robert Herrick": (None, None),  # baptized 08-1591; died October 1674 (day unknown)
    "John Donne": (None, "03-31"),  # birth day unknown (only the year 1572)
    "George Herbert": ("04-03", "03-01"),
    "Ben Jonson": ("06-11", "08-06"),  # birth traditional
    "Sir Philip Sidney": ("11-30", "10-17"),
    "Thomas Gray": ("12-26", "07-30"),
    "Oliver Goldsmith": ("11-10", "04-04"),
    "John Clare": ("07-13", "05-20"),
    "Walter Savage Landor": ("01-30", "09-17"),
    "Gerard Manley Hopkins": ("07-28", "06-08"),
    "Ernest Dowson": ("08-02", "02-23"),
    "Stephen Crane": ("11-01", "06-05"),
    "Paul Laurence Dunbar": ("06-27", "02-09"),
    "Edgar Allan Poe": ("01-19", "10-07"),
    "Oscar Wilde": ("10-16", "11-30"),
    "Lewis Carroll": ("01-27", "01-14"),
    "William Cowper": ("11-26", "04-25"),
    "Thomas Hood": ("05-23", "05-03"),
    "Thomas Moore": ("05-28", "02-25"),
    "Thomas Campbell": ("07-27", "06-15"),
    "Sir John Suckling": ("02-10", "07-01"),  # birth traditional (baptism)
    "Richard Lovelace": (None, None),  # died April 1658 (day unknown)
    "Mary Elizabeth Coleridge": ("12-23", "08-25"),
    "Amy Levy": ("11-10", "09-10"),
    "Jane Taylor": ("09-23", "04-13"),
    "Ann Taylor": ("01-30", "12-11"),
    "Katherine Philips": ("01-01", "06-22"),  # birth: baptism 01-01-1631/32
    "Andrew Marvell": ("03-31", "08-16"),
    "Christopher Marlowe": ("02-26", "05-30"),  # birth: baptism
    "Edmund Spenser": (None, "01-13"),  # birth unknown (c. 1552)
    "John Milton": ("12-09", "11-08"),
    "William Cullen Bryant": ("11-03", "06-12"),
    "Henry Wadsworth Longfellow": ("02-27", "03-24"),
    "Oliver Wendell Holmes": ("08-29", "10-07"),
    "Ralph Waldo Emerson": ("05-25", "04-27"),
    "John Greenleaf Whittier": ("12-17", "09-07"),
    "Rupert Brooke": ("08-03", "04-23"),
    "Edward Thomas": ("03-03", "04-09"),
    "Wilfred Owen": ("03-18", "11-04"),
    "William Barnes": ("02-22", "10-07"),
    "William Allingham": ("03-19", "11-18"),
    "Robert Southey": ("08-12", "03-21"),
    "Isaac Watts": ("07-17", "11-25"),
    "Emma Lazarus": ("07-22", "11-19"),
    "Sidney Lanier": ("02-03", "09-07"),
    "James Henry Leigh Hunt": ("10-19", "08-28"),
    "Eugene Field": ("09-02", "11-04"),
    "Joyce Kilmer": ("12-06", "07-30"),
    "John McCrae": ("11-30", "01-28"),
    "Matthew Arnold": ("12-24", "04-15"),
    "Henry Vaughan": ("04-17", "04-23"),  # birth: baptism
}

# PoetryDB writes "Emily Brontë" with the diaeresis.
POETRYDB_NAME_FIXUPS = {"Emily Bronte": "Emily Brontë"}

# Season keyword stems, matched case-insensitively at a word start. Deliberately
# conservative; tags are a soft preference, never a hard filter.
SEASON_KEYWORDS = {
    "spring": ["spring", "blossom", "daffodil", "crocus", "primrose", "lilac",
               "bluebell", "thaw", "vernal", "april", "march", "may"],
    "summer": ["summer", "midsummer", "june", "july", "august"],
    "autumn": ["autumn", "fall", "harvest", "september", "october", "november"],
    "winter": ["winter", "snow", "frost", "icy", "december", "january", "february"],
}
MONTH_NAMES = ["january", "february", "march", "april", "may", "june", "july",
               "august", "september", "october", "november", "december"]

SEASON_PATTERNS = {season: re.compile(r"\b(?:" + "|".join(stems) + ")", re.IGNORECASE)
                   for season, stems in SEASON_KEYWORDS.items()}
# Month-name matches are case-insensitive except for the ambiguous verb/adjective
# homographs (may, march, august): those need the capitalized month form.
AMBIGUOUS_MONTHS = {"may", "march", "august"}
MONTH_PATTERNS = {index + 1: re.compile(r"\b" + name + r"\b",
                                        re.NOFLAG if name in AMBIGUOUS_MONTHS else re.IGNORECASE)
                  for index, name in enumerate(MONTH_NAMES)}

# Residual OCR/typography artifacts that make a line unusable.
BAD_LINE = re.compile(r"[\[\]_]|\*\*\*|^\s*§")
WHITESPACE_RUN = re.compile(r"\s+")


def fetch_json(url: str, cache_name: str, refetch: bool):
    """GETs JSON with a disk cache; network failures fall back to the cache."""
    cache_path = CACHE / cache_name
    if not refetch and cache_path.exists():
        return json.loads(cache_path.read_text(encoding="utf-8"))
    request = urllib.request.Request(url, headers={"User-Agent": "caesura-curator/1"})
    with urllib.request.urlopen(request, timeout=60) as response:
        data = response.read()
    parsed = json.loads(data.decode("utf-8"))
    CACHE.mkdir(parents=True, exist_ok=True)
    cache_path.write_text(json.dumps(parsed, ensure_ascii=False), encoding="utf-8")
    return parsed


def author_cache_slug(author: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", author.lower()).strip("-")


def fetch_author_poems(author: str, refetch: bool):
    slug = author_cache_slug(author)
    query = urllib.parse.quote(f"{author}:abs")
    url = f"https://poetrydb.org/author/{query}/author,title,lines,linecount"
    return fetch_json(url, f"author-{slug}.json", refetch)


def fetch_author_info(author: str, refetch: bool):
    slug = author_cache_slug(author)
    query = urllib.parse.quote(f"{author}:abs")
    url = f"https://poetrydb.org/author/{query}/info"
    return fetch_json(url, f"info-{slug}.json", refetch)


def clean_lines(lines):
    """Normalizes whitespace, drops artifact lines, keeps stanza-break blanks."""
    cleaned = []
    for line in lines:
        if BAD_LINE.search(line):
            continue
        line = WHITESPACE_RUN.sub(" ", line).strip()
        cleaned.append(line)
    # Collapse runs of blank lines to a single stanza break.
    collapsed = []
    for line in cleaned:
        if line == "" and (not collapsed or collapsed[-1] == ""):
            continue
        collapsed.append(line)
    while collapsed and collapsed[0] == "":
        collapsed.pop(0)
    while collapsed and collapsed[-1] == "":
        collapsed.pop()
    return collapsed


def content_lines(lines):
    return [line for line in lines if line != ""]


def excerpt_of(lines):
    """First complete stanza of <= 4 lines; else the first 4 content lines."""
    stanza = []
    for line in lines + [""]:
        if line == "":
            if 1 <= len(stanza) <= EXCERPT_LINES:
                return stanza
            stanza = []
        else:
            stanza.append(line)
    return content_lines(lines)[:EXCERPT_LINES]


def tag_seasons_and_months(title, lines):
    text = [title] + lines
    seasons = sorted({season for season, pattern in SEASON_PATTERNS.items()
                      if any(pattern.search(line) for line in text)})
    months = sorted({month for month, pattern in MONTH_PATTERNS.items()
                     if any(pattern.search(line) for line in text)})
    return seasons, months


def slugify(author: str, title: str) -> str:
    text = re.sub(r"[^a-z0-9]+", "-", f"{author}-{title}".lower()).strip("-")
    return text[:80].rstrip("-")


def load_overrides():
    if not OVERRIDES.exists():
        return {}
    return json.loads(OVERRIDES.read_text(encoding="utf-8"))


def apply_overrides(poems, overrides):
    excluded = set(overrides.get("exclude", []))
    add_seasons = overrides.get("addSeasons", {})
    remove_seasons = overrides.get("removeSeasons", {})
    add_months = overrides.get("addMonths", {})
    remove_months = overrides.get("removeMonths", {})
    kept = []
    for poem in poems:
        if poem["id"] in excluded:
            continue
        poem["seasons"] = sorted(set(poem["seasons"]) | set(add_seasons.get(poem["id"], []))
                                 - set(remove_seasons.get(poem["id"], [])))
        poem["months"] = sorted(set(poem["months"]) | set(add_months.get(poem["id"], []))
                                - set(remove_months.get(poem["id"], [])))
        kept.append(poem)
    return kept


def evenly_spaced(items, count):
    """Deterministic spread over a title-sorted list (keeps variety, no RNG)."""
    if len(items) <= count:
        return list(items)
    step = len(items) / count
    return [items[int(index * step)] for index in range(count)]


def curate(refetch: bool, cap: int, min_count: int):
    poems_by_author = {}
    missing_authors = []
    info_years = {}
    for author in AUTHOR_ANNIVERSARIES:
        response = fetch_author_poems(author, refetch)
        if not isinstance(response, list):
            missing_authors.append(author)
            continue
        try:
            info = fetch_author_info(author, refetch)
            if isinstance(info, list) and info:
                info_years[author] = (info[0].get("born"), info[0].get("died"))
        except (OSError, ValueError, KeyError, IndexError) as error:  # info is advisory only
            print(f"  info fetch failed for {author}: {error}", file=sys.stderr)
        poems_by_author[author] = response
    for author in missing_authors:
        print(f"WARNING: PoetryDB returned no poems for {author!r} "
              "(check the spelling against https://poetrydb.org/author)", file=sys.stderr)

    selected = []
    seen_keys = set()
    seen_ids = set()

    def collect(cap_value):
        del selected[:]
        seen_keys.clear()
        seen_ids.clear()
        for author, response in poems_by_author.items():
            db_name = POETRYDB_NAME_FIXUPS.get(author, author)
            born, died = AUTHOR_ANNIVERSARIES[author]
            candidates = []
            for entry in response:
                if not isinstance(entry, dict) or "lines" not in entry:
                    continue
                lines = clean_lines(entry.get("lines", []))
                content = content_lines(lines)
                if not (MIN_LINES <= len(content) <= MAX_LINES):
                    continue
                candidates.append((entry.get("title", "").strip(), lines))
            candidates.sort(key=lambda item: item[0].casefold())
            for title, lines in evenly_spaced(candidates, cap_value):
                key = (title.casefold(), db_name.casefold())
                if key in seen_keys:
                    continue
                poem_id = slugify(db_name, title)
                while poem_id in seen_ids:
                    poem_id += "-x"
                seen_ids.add(poem_id)
                seen_keys.add(key)
                seasons, months = tag_seasons_and_months(title, lines)
                selected.append({
                    "id": poem_id,
                    "title": title,
                    "author": db_name,
                    "lines": lines,
                    "excerpt": excerpt_of(lines),
                    "seasons": seasons,
                    "months": months,
                    "authorBorn": born,
                    "authorDied": died,
                    "source": "PoetryDB",
                })

    collect(cap)
    attempt = cap
    while len(selected) < min_count and attempt < 200:
        attempt += 10
        collect(attempt)

    overrides = load_overrides()
    kept = apply_overrides(selected, overrides)
    kept.sort(key=lambda poem: (poem["author"].casefold(), poem["title"].casefold()))
    return kept, info_years


def write_catalog(poems):
    catalog = {
        "version": CATALOG_VERSION,
        "language": "en",
        "attribution": ATTRIBUTION,
        "poems": poems,
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(catalog, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def report(poems, info_years):
    print(f"poems: {len(poems)} -> {OUT.relative_to(ROOT)}")
    per_author = {}
    for poem in poems:
        per_author[poem["author"]] = per_author.get(poem["author"], 0) + 1
    for author in sorted(per_author):
        years = info_years.get(author)
        print(f"  {author}: {per_author[author]} (info born/died: {years[0]}/{years[1]})" if years
              else f"  {author}: {per_author[author]} (no info)")
    for label, key, values in (("seasons", "seasons", sorted(SEASON_KEYWORDS)),
                               ("months", "months", range(1, 13))):
        counts = {value: sum(1 for poem in poems if value in poem[key]) for value in values}
        print(f"{label}: {counts}")
    tagged = sum(1 for poem in poems if poem["seasons"] or poem["months"])
    anniversaries = sum(1 for poem in poems if poem["authorBorn"] or poem["authorDied"])
    print(f"tagged poems: {tagged}/{len(poems)}, anniversary-capable: {anniversaries}/{len(poems)}")
    lengths = sorted(len(content_lines(poem["lines"])) for poem in poems)
    print(f"content lines: min {lengths[0]}, median {lengths[len(lengths) // 2]}, max {lengths[-1]}")


def sample(poems, count):
    for poem in random.sample(poems, min(count, len(poems))):
        tags = ",".join(poem["seasons"]) + "/" + ",".join(str(m) for m in poem["months"])
        print(f"--- {poem['id']} [{tags}] born={poem['authorBorn']} died={poem['authorDied']}")
        print(f"    {poem['title']} — {poem['author']}")
        for line in poem["excerpt"]:
            print(f"    | {line}")


def inspect(poems, poem_id):
    for poem in poems:
        if poem["id"] == poem_id:
            print(json.dumps(poem, ensure_ascii=False, indent=2))
            return
    print(f"no poem with id {poem_id!r}", file=sys.stderr)
    sys.exit(1)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--refetch", action="store_true", help="ignore the response cache")
    parser.add_argument("--cap", type=int, default=25, help="max poems per author")
    parser.add_argument("--min-count", type=int, default=400, help="raise the cap until this many poems")
    parser.add_argument("--sample", type=int, default=0, help="print N random poems for the spot check")
    parser.add_argument("--inspect", metavar="POEM_ID", help="print one poem as JSON")
    args = parser.parse_args()
    poems, info_years = curate(refetch=args.refetch, cap=args.cap, min_count=args.min_count)
    report(poems, info_years)
    if args.inspect:
        inspect(poems, args.inspect)
    if args.sample:
        sample(poems, args.sample)
    if len(poems) < 366:
        print("FAIL: fewer than 366 poems — extend the author whitelist", file=sys.stderr)
        sys.exit(1)
    write_catalog(poems)


if __name__ == "__main__":
    main()
