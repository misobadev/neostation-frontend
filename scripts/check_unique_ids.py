#!/usr/bin/env python3
import json
import sys
from pathlib import Path


def main():
    # The scripts live in scripts/, one level below the repository root.
    systems_dir = Path(__file__).resolve().parent.parent / "assets" / "systems"
    files = sorted(systems_dir.glob("*.json"))
    if not files:
        # A wrong path must not pass as "no duplicates".
        print(f"ERROR: no systems JSON found in {systems_dir}")
        sys.exit(1)
    seen = {}  # unique_id -> source file
    duplicates = []

    for json_file in files:
        try:
            data = json.loads(json_file.read_text(encoding="utf-8"))
        except json.JSONDecodeError as e:
            print(f"ERROR: invalid JSON in {json_file.name}: {e}")
            sys.exit(1)

        emulators = data.get("emulators", [])
        for emulator in emulators:
            uid = emulator.get("unique_id")
            if not uid:
                continue
            if uid in seen:
                duplicates.append((uid, seen[uid], json_file.name))
            else:
                seen[uid] = json_file.name

    if duplicates:
        print(f"FAIL: found {len(duplicates)} duplicate unique_id(s):\n")
        for uid, first, second in duplicates:
            print(f"  '{uid}'")
            print(f"    first:  {first}")
            print(f"    second: {second}")
        sys.exit(1)

    print(f"OK: {len(seen)} unique_id(s) checked, no duplicates found.")


if __name__ == "__main__":
    main()
