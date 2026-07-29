#!/usr/bin/env python3
"""Deterministic extract/merge for Localizable.xcstrings.

Usage:
  l10n_tool.py extract               -> writes l10n_source.json  (key -> english source)
  l10n_tool.py merge                 -> reads l10n_translations.json, writes fr+de into the catalog
  l10n_tool.py verify                -> reports how many keys still lack fr/de and any placeholder drift

The source string for a key is:
  - localizations.en.stringUnit.value  when that block exists
  - otherwise the key itself (Xcode uses the key as the source-language value)

Merge NEVER touches the en value and NEVER reorders keys. It only adds/overwrites
the fr and de stringUnit blocks (state: "translated").
"""
import json, re, sys, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOG = ROOT / "Localizable.xcstrings"
SOURCE = ROOT / "scripts" / "l10n_source.json"
TRANS = ROOT / "scripts" / "l10n_translations.json"
FR = ROOT / "scripts" / "l10n_fr.json"
DE = ROOT / "scripts" / "l10n_de.json"

# Tokens that MUST survive translation unchanged, in order.
PLACEHOLDER = re.compile(r'%(?:\d+\$)?(?:@|lld|lf|d|f|ld)|\\\([^)]*\)')

def english_source(key, entry):
    loc = entry.get("localizations", {})
    en = loc.get("en", {}).get("stringUnit", {}).get("value")
    return en if en is not None else key

def placeholders(s):
    return PLACEHOLDER.findall(s)

def load_catalog():
    return json.loads(CATALOG.read_text(encoding="utf-8"))

def cmd_extract():
    cat = load_catalog()
    out = {}
    for key, entry in cat["strings"].items():
        out[key] = english_source(key, entry)
    SOURCE.write_text(json.dumps(out, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"wrote {SOURCE} with {len(out)} source strings")

def cmd_merge():
    cat = load_catalog()
    trans = json.loads(TRANS.read_text(encoding="utf-8"))
    missing, drift, merged = [], [], 0
    for key, entry in cat["strings"].items():
        t = trans.get(key)
        if not t or not t.get("fr") or not t.get("de"):
            missing.append(key)
            continue
        src = english_source(key, entry)
        src_ph = sorted(placeholders(src))
        for lang in ("fr", "de"):
            if sorted(placeholders(t[lang])) != src_ph:
                drift.append((key, lang, src, t[lang]))
        loc = entry.setdefault("localizations", {})
        for lang in ("fr", "de"):
            loc[lang] = {"stringUnit": {"state": "translated", "value": t[lang]}}
        merged += 1
    # Stable, Xcode-compatible formatting: 2-space indent, sorted keys off (preserve order).
    CATALOG.write_text(json.dumps(cat, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"merged fr+de into {merged} keys")
    if missing:
        print(f"WARNING: {len(missing)} keys still missing a translation, e.g. {missing[:5]}")
    if drift:
        print(f"WARNING: {len(drift)} placeholder mismatches, e.g. {drift[:3]}")

def cmd_combine():
    """Build l10n_translations.json from per-language l10n_fr.json + l10n_de.json.
    Each per-language file is {key: "translation"}. Reports keys missing from either."""
    fr = json.loads(FR.read_text(encoding="utf-8"))
    de = json.loads(DE.read_text(encoding="utf-8"))
    src = json.loads(SOURCE.read_text(encoding="utf-8"))
    out, miss_fr, miss_de = {}, [], []
    for key in src:
        f, d = fr.get(key), de.get(key)
        if f is None: miss_fr.append(key)
        if d is None: miss_de.append(key)
        if f is not None and d is not None:
            out[key] = {"fr": f, "de": d}
    TRANS.write_text(json.dumps(out, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"combined {len(out)}/{len(src)} keys into {TRANS}")
    if miss_fr: print(f"missing fr: {len(miss_fr)} e.g. {miss_fr[:5]}")
    if miss_de: print(f"missing de: {len(miss_de)} e.g. {miss_de[:5]}")

def cmd_addnew():
    """Add brand-new keys (not yet in the catalog) from _new_strings_translated.json.

    These are strings introduced by the items 1/2/3/5 work. Xcode would extract
    them itself on the next Mac build, but it would extract them UNTRANSLATED —
    adding them here with fr+de means they ship localized. extractionState is
    "manual" because they were added without running Xcode's extractor.
    """
    cat = load_catalog()
    new = json.loads((ROOT / "scripts" / "_new_strings_translated.json").read_text(encoding="utf-8"))
    added, already = 0, 0
    for key, t in new.items():
        if key in cat["strings"]:
            already += 1
            continue
        cat["strings"][key] = {
            "extractionState": "manual",
            "localizations": {
                lang: {"stringUnit": {"state": "translated", "value": val}}
                for lang, val in (("en", key), ("fr", t["fr"]), ("de", t["de"]))
            },
        }
        added += 1
    # Existing key order is left untouched: the catalog is sorted with Xcode's
    # own locale-aware collation, which does not match Python's byte sort, so
    # re-sorting here would rewrite all 839 entries for nothing and Xcode would
    # put them back on the next save. New keys are simply appended; Xcode files
    # them in place the first time it writes the catalog.
    CATALOG.write_text(json.dumps(cat, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"added {added} new keys ({already} already present); catalog now {len(cat['strings'])} keys")

def cmd_verify():
    cat = load_catalog()
    no_fr = [k for k, e in cat["strings"].items() if "fr" not in e.get("localizations", {})]
    no_de = [k for k, e in cat["strings"].items() if "de" not in e.get("localizations", {})]
    print(f"total keys: {len(cat['strings'])}")
    print(f"missing fr: {len(no_fr)} | missing de: {len(no_de)}")
    if no_fr[:5]: print("first missing fr:", no_fr[:5])

if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    {"extract": cmd_extract, "combine": cmd_combine, "merge": cmd_merge,
     "addnew": cmd_addnew, "verify": cmd_verify}.get(cmd, lambda: print(__doc__))()
