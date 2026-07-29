# Localization workflow (`Localizable.xcstrings`)

The app ships **en / fr / de**. `Localizable.xcstrings` is a single string
catalog, resource of both the iOS app and the widget extension; `knownRegions`
in `project.pbxproj` lists `en, Base, fr, de`.

The catalog is a large JSON file and must never be hand-edited — one stray
comma corrupts every string in the app. `l10n_tool.py` is the only supported
way to write to it.

## Commands

```sh
python3 scripts/l10n_tool.py extract   # catalog  -> scripts/l10n_source.json  (key -> english)
python3 scripts/l10n_tool.py combine   # l10n_fr.json + l10n_de.json -> l10n_translations.json
python3 scripts/l10n_tool.py merge     # writes fr+de into EXISTING catalog keys
python3 scripts/l10n_tool.py addnew    # adds brand-new keys from _new_strings_translated.json
python3 scripts/l10n_tool.py verify    # how many keys still lack fr/de
```

The English source for a key is `localizations.en.stringUnit.value` when that
block exists, otherwise the key itself — which is how Xcode represents a string
whose source-language value is unchanged. Roughly two thirds of the catalog has
no `en` block for that reason.

`merge` never touches the `en` value and never reorders keys. `addnew` appends;
it deliberately does **not** re-sort, because the catalog is ordered with
Xcode's locale-aware collation, which is not Python's byte order — re-sorting
would rewrite the whole file and Xcode would undo it on the next save.

## Guardrails

`merge` compares the placeholder set (`%@`, `%lld`, `%1$@`, `\(...)`) of every
translation against its source and warns on any mismatch. A dropped or invented
placeholder is the one localization bug that crashes at runtime rather than
merely reading badly, so this check is not optional.

## Adding a language

1. `extract`, then produce `scripts/l10n_<lang>.json` — `{key: translation}`
   keyed exactly as `l10n_source.json`.
2. Add the language to `combine`/`merge` in `l10n_tool.py` and to
   `knownRegions` in `project.pbxproj`.
3. `combine` → `merge` → `verify`.

## Known gap — strings added since the last extraction

Extraction of new `String(localized:)` / `Text("…")` literals is Xcode's job and
needs a Mac; it cannot run here. `addnew` pre-loads the catalog with the
non-interpolated literals introduced by the flyability-verdict / beacon /
onboarding work, so they ship translated.

**Interpolated** strings (e.g.
`String(localized: "Wind is from the \(source) — you fly here in \(list).")`)
are *not* pre-loaded: their catalog key depends on the interpolated types
(`%@` vs `%lld`), which cannot be resolved without compiling. Xcode will extract
them on the next Mac build and they will appear **untranslated (English)** until
someone runs `extract` → translate → `merge` again. That pass is the intended
follow-up, not an oversight.
