#!/usr/bin/env python3
import json
import sys
from pathlib import Path


def format_file(json_file: Path) -> str:
    original = json_file.read_text(encoding="utf-8")
    try:
        data = json.loads(original)
    except json.JSONDecodeError as e:
        print(f"ERROR: invalid JSON in {json_file.name}: {e}")
        return "error"

    formatted = json.dumps(data, indent=2, ensure_ascii=False) + "\n"
    if original != formatted:
        json_file.write_text(formatted, encoding="utf-8")
        print(f"  formatted: {json_file.name}")
        return "changed"
    return "ok"


def main():
    # The scripts live in scripts/, one level below the repository root.
    systems_dir = Path(__file__).resolve().parent.parent / "assets" / "systems"
    files = sorted(systems_dir.glob("*.json"))
    if not files:
        # A wrong path must not pass as "nothing to reformat".
        print(f"ERROR: no systems JSON found in {systems_dir}")
        sys.exit(1)

    changed = 0
    errors = 0
    for json_file in files:
        result = format_file(json_file)
        if result == "changed":
            changed += 1
        elif result == "error":
            errors += 1

    print(f"\n{changed}/{len(files)} files reformatted.")
    if errors:
        print(f"{errors} file(s) with errors.")
        sys.exit(1)


if __name__ == "__main__":
    main()
