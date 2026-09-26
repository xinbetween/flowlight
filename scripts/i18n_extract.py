#!/usr/bin/env python3
"""Every string SwiftUI will look up in Localizable.strings, straight from the source.

The app has no `String(localized:)` calls: it relies on SwiftUI taking a literal as a `LocalizedStringKey`, so
the key *is* the English text and an untranslated string still shows correct English. That makes the catalog
derivable — this script reads the literals back out of the Swift files, so a translation pass can be checked
rather than eyeballed.

  python3 scripts/i18n_extract.py            # the keys, one per line
  python3 scripts/i18n_extract.py --context  # each key with the files it appears in
  python3 scripts/i18n_extract.py --check    # per-language coverage, exit 1 if a catalog has stray keys

A literal SwiftUI would localize on its own is not enough: `Text("Live")` follows the Mac's language, while the
in-app Language setting only reaches strings that go through `L()`. So the rule the source follows — and what
this reads back — is that every user-facing string is written `L("…")`.
"""
import re, sys, pathlib, collections

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Flowlight"
CATALOGS = sorted((ROOT / "Flowlight/Localization").glob("*.lproj/Localizable.strings"))

# Every lookup goes through `L("…")` (see Flowlight/Localization/Localization.swift), so the catalog is exactly
# the set of keys written there. `L("…", args)` is the format variant: its key carries %@ / %lld and is included.
CALL = re.compile(r'\bL\(\s*"((?:[^"\\]|\\.)+)"')
ENTRY = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;')


def literals():
    """key -> the files it is written in, in source order."""
    found: dict[str, list[str]] = collections.OrderedDict()
    for path in sorted(SOURCE.rglob("*.swift")):
        for match in CALL.finditer(path.read_text()):
            key = match.group(1)
            if len(key) < 2 or not any(c.isalpha() for c in key):
                continue
            where = str(path.relative_to(ROOT))
            found.setdefault(key, [])
            if where not in found[key]:
                found[key].append(where)
    return found


def catalog(path):
    out = {}
    for line in path.read_text().splitlines():
        m = ENTRY.match(line)
        if m:
            out[m.group(1)] = m.group(2)
    return out


def main():
    keys = literals()
    if "--check" in sys.argv:
        stray = False
        print(f"{len(keys)} keys in the source\n")
        for path in CATALOGS:
            entries = catalog(path)
            lang = path.parent.name.removesuffix(".lproj")
            missing = [k for k in keys if k not in entries]
            # A key nothing in the source asks for is dead weight — or a typo that will never match.
            unused = [k for k in entries if k not in keys]
            print(f"  {lang:8} {len(entries) - len(unused):4}/{len(keys)} translated"
                  f"{'':4}{len(missing):4} missing{'':4}{len(unused):4} not in source")
            if unused and "--verbose" in sys.argv:
                for k in unused:
                    print(f"      unused: {k!r}")
            stray = stray or bool(unused)
        return 1 if stray else 0
    for key, where in keys.items():
        print(f"{key}\t{', '.join(where)}" if "--context" in sys.argv else key)
    return 0


if __name__ == "__main__":
    sys.exit(main())
