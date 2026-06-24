#!/usr/bin/env python3
"""
Generates assets/data/ra_insert.sql from the RetroAchievements API.

Fetches all active game consoles via API_GetConsoleIDs.php, then for each
console fetches every game (paginated) via API_GetGameList.php and writes
INSERT statements into app_ra_game_list — one row per game hash.

Usage:
    python scripts/generate_ra_insert.py
"""

import json
import time
import urllib.request
import urllib.parse
import os
import re
from datetime import datetime


def load_env_key() -> str:
    env_path = os.path.join(
        os.path.dirname(os.path.dirname(__file__)), ".env"
    )
    if os.path.exists(env_path):
        with open(env_path) as f:
            for line in f:
                m = re.match(r"^RA_API_KEY\s*=\s*(\S+)", line.strip())
                if m:
                    return m.group(1)
    key = os.environ.get("RA_API_KEY")
    if key:
        return key
    raise SystemExit(
        "ERROR: RA_API_KEY not found in .env or environment variables"
    )


API_KEY = load_env_key()
BASE_URL = "https://retroachievements.org/API"

OUTPUT = os.path.join(
    os.path.dirname(os.path.dirname(__file__)),
    "assets/data/ra_insert.sql",
)

PAGE_SIZE = 500
REQUEST_DELAY = 0.3
RETRY_DELAY = 5.0
MAX_RETRIES = 3


def api_get(path: str, retries: int = MAX_RETRIES) -> dict | list:
    url = f"{BASE_URL}/{path}"
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "NeoStation/1.0"})
            with urllib.request.urlopen(req, timeout=30) as resp:
                return json.loads(resp.read().decode())
        except urllib.error.HTTPError as e:
            if e.code == 429 and attempt < retries - 1:
                wait = RETRY_DELAY * (attempt + 1)
                print(f"  429 rate limited, retrying in {wait}s...")
                time.sleep(wait)
                continue
            raise
    raise RuntimeError(f"Failed after {retries} retries: {url}")


def fetch_consoles() -> list[dict]:
    return api_get(f"API_GetConsoleIDs.php?y={API_KEY}&a=1&g=1")


def fetch_games(console_id: int, offset: int = 0) -> list[dict]:
    params = urllib.parse.urlencode({
        "y": API_KEY,
        "i": console_id,
        "f": 1,
        "h": 1,
        "o": offset,
        "c": PAGE_SIZE,
    })
    return api_get(f"API_GetGameList.php?{params}")


def sql_str(val) -> str:
    if val is None:
        return "NULL"
    s = str(val)
    s = s.replace("'", "''")
    return f"'{s}'"


def sql_int(val) -> str:
    if val is None:
        return "NULL"
    return str(int(val))


def main():
    print("Fetching console list...")
    consoles = fetch_consoles()
    active_game_consoles = [
        c for c in consoles if c.get("Active") and c.get("IsGameSystem")
    ]
    print(f"Found {len(consoles)} total, {len(active_game_consoles)} active game consoles")

    all_rows: list[tuple[int, dict, str]] = []
    unique_games = 0

    for idx, console in enumerate(active_game_consoles):
        cid = console["ID"]
        cname = console.get("Name", f"Console {cid}")
        offset = 0
        console_games = 0
        console_hashes = 0

        print(f"[{idx + 1}/{len(active_game_consoles)}] Console {cid} ({cname})...")

        while True:
            games = fetch_games(cid, offset)
            if not games:
                break

            for game in games:
                hashes = game.get("Hashes")
                if not hashes:
                    continue
                unique_games += 1
                console_games += 1
                for h in hashes:
                    if h:
                        all_rows.append((game, h))
                        console_hashes += 1

            if len(games) < PAGE_SIZE:
                break
            offset += PAGE_SIZE
            time.sleep(REQUEST_DELAY)

        print(
            f"   -> {console_games} games, {console_hashes} hashes"
            if console_games > 0
            else f"   -> (no games)"
        )
        time.sleep(REQUEST_DELAY)

    total_rows = len(all_rows)
    print(f"\n=== Summary ===")
    print(f"Consoles: {len(active_game_consoles)}")
    print(f"Unique games: {unique_games}")
    print(f"Total rows (per hash): {total_rows}")

    now_str = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    lines = [
        f"-- RetroAchievements database",
        f"-- Auto-generated on {now_str}",
        f"-- Consoles: {len(active_game_consoles)}",
        f"-- Games: {unique_games}",
        "",
        "-- ===========================================",
        "-- TABLE: app_ra_game_list",
        "-- ===========================================",
        "",
    ]

    columns = [
        "id", "game_id", "title", "console_id", "console_name",
        "image_icon", "num_achievements", "num_leaderboards", "points",
        "date_modified", "forum_topic_id", "hash",
    ]

    batch_size = 100

    for batch_start in range(0, total_rows, batch_size):
        batch = all_rows[batch_start:batch_start + batch_size]
        batch_end = min(batch_start + batch_size, total_rows)
        lines.append(f"-- Batch {(batch_start // batch_size) + 1}: games {batch_start + 1} - {batch_end}")

        for row_num_offset, (game, hash_val) in enumerate(batch):
            row_num = batch_start + row_num_offset + 1
            vals = [
                str(row_num),
                sql_int(game.get("ID")),
                sql_str(game.get("Title", "")),
                sql_int(game.get("ConsoleID")),
                sql_str(game.get("ConsoleName", "")),
                sql_str(game.get("ImageIcon")),
                sql_int(game.get("NumAchievements")),
                sql_int(game.get("NumLeaderboards")),
                sql_int(game.get("Points")),
                sql_str(game.get("DateModified")),
                sql_int(game.get("ForumTopicID")),
                sql_str(hash_val),
            ]
            lines.append(
                f"INSERT INTO app_ra_game_list "
                f"({', '.join(columns)}) VALUES "
                f"({', '.join(vals)});"
            )

        lines.append("")

    content = "\n".join(lines)

    os.makedirs(os.path.dirname(OUTPUT), exist_ok=True)
    with open(OUTPUT, "w", encoding="utf-8") as f:
        f.write(content)

    print(f"\nWritten to {OUTPUT}")
    print(f"Total lines: {len(lines)}")
    print(f"Total INSERT statements: {total_rows}")


if __name__ == "__main__":
    main()
