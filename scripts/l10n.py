#!/usr/bin/env python3
"""String Catalog helper. xcodebuild does not write new keys into Localizable.xcstrings, so:

  scripts/l10n.py missing             # list keys used in the last Debug build but absent from the catalog
  scripts/l10n.py add vi.json         # merge {"English key": "Vietnamese value", ...} into the catalog
  scripts/l10n.py add-verbatim k1 k2  # mark keys as not translatable

Run `make build` first so build/ holds fresh .stringsdata files.
"""
import glob
import json
import sys

CATALOG = "Osin/Resources/Localizable.xcstrings"


def load():
    with open(CATALOG, encoding="utf-8") as f:
        return json.load(f)


def save(catalog):
    catalog["strings"] = dict(sorted(catalog["strings"].items()))
    with open(CATALOG, "w", encoding="utf-8") as f:
        json.dump(catalog, f, ensure_ascii=False, indent=2)
        f.write("\n")


def used_keys():
    keys = set()
    for path in glob.glob("build/Build/Intermediates.noindex/**/Debug/**/*.stringsdata", recursive=True):
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        for entries in data.get("tables", {}).values():
            keys.update(entry["key"] for entry in entries)
    return keys


def main():
    command = sys.argv[1] if len(sys.argv) > 1 else "missing"
    catalog = load()
    if command == "missing":
        missing = sorted(k for k in used_keys() if k not in catalog["strings"])
        print(json.dumps(missing, ensure_ascii=False, indent=2))
        sys.exit(1 if missing else 0)
    elif command == "add":
        with open(sys.argv[2], encoding="utf-8") as f:
            translations = json.load(f)
        for key, value in translations.items():
            catalog["strings"][key] = {"localizations": {"vi": {"stringUnit": {"state": "translated", "value": value}}}}
        save(catalog)
    elif command == "add-verbatim":
        for key in sys.argv[2:]:
            catalog["strings"][key] = {"shouldTranslate": False}
        save(catalog)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
