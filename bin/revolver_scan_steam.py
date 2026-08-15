#!/usr/bin/env python3
"""
revolver-scan-steam

Scans the local Steam library (no Web API key needed) and prints a JSON
array of installed games, each weighted toward titles played recently /
in the last two weeks:

    [{"appid": 620, "name": "Portal 2", "weight": 41.0}, ...]

Used by the illogical-impulse "Revolver Barrel" Quickshell widget to load
its six chambers on each pull of the trigger.
"""
import json
import re
import sys
import time
from pathlib import Path

STEAM_ROOTS = [
    "~/.local/share/Steam",
    "~/.steam/steam",
    "~/.steam/root",
    "~/.var/app/com.valvesoftware.Steam/.local/share/Steam",  # flatpak
]


def find_steam_root():
    for p in STEAM_ROOTS:
        path = Path(p).expanduser()
        if (path / "steamapps").is_dir():
            return path
    return None


def parse_vdf(text):
    """Minimal recursive-descent parser for Valve's text KeyValues (VDF)
    format. Returns the full document as a dict of top-level key/value
    pairs (values are either strings or nested dicts)."""
    pos = 0
    length = len(text)

    def skip_ws():
        nonlocal pos
        while pos < length:
            c = text[pos]
            if c in " \t\r\n":
                pos += 1
            elif c == "/" and pos + 1 < length and text[pos + 1] == "/":
                while pos < length and text[pos] != "\n":
                    pos += 1
            else:
                break

    def read_token():
        nonlocal pos
        skip_ws()
        if pos >= length:
            return None
        if text[pos] == '"':
            pos += 1
            buf = []
            while pos < length and text[pos] != '"':
                if text[pos] == "\\" and pos + 1 < length:
                    buf.append(text[pos + 1])
                    pos += 2
                else:
                    buf.append(text[pos])
                    pos += 1
            pos += 1  # closing quote
            return "".join(buf)
        if text[pos] in "{}":
            tok = text[pos]
            pos += 1
            return tok
        start = pos
        while pos < length and text[pos] not in " \t\r\n{}\"":
            pos += 1
        return text[start:pos] if pos > start else None

    def set_kv(obj, key, val):
        if key in obj:
            if isinstance(obj[key], list):
                obj[key].append(val)
            else:
                obj[key] = [obj[key], val]
        else:
            obj[key] = val

    def parse_object():
        obj = {}
        while True:
            key = read_token()
            if key is None or key == "}":
                break
            skip_ws()
            if pos < length and text[pos] == "{":
                read_token()  # consume '{'
                val = parse_object()
            else:
                val = read_token()
            set_kv(obj, key, val)
        return obj

    def parse_document():
        doc = {}
        while True:
            skip_ws()
            if pos >= length:
                break
            key = read_token()
            if key is None:
                break
            skip_ws()
            if pos < length and text[pos] == "{":
                read_token()
                val = parse_object()
            else:
                val = read_token()
            set_kv(doc, key, val)
        return doc

    return parse_document()


def load_vdf(path):
    try:
        return parse_vdf(path.read_text(errors="ignore"))
    except FileNotFoundError:
        return {}


# Steam tags compatibility tools/runtimes/redistributables with their own
# appmanifest_*.acf just like real games. Filter them out by name so the
# barrel never chambers "Proton 8.0".
NON_GAME_PATTERNS = [
    re.compile(r"^Proton\b"),
    re.compile(r"^Steam Linux Runtime"),
    re.compile(r"^Steamworks Common Redistributables$"),
]


def is_probably_game(name):
    return not any(p.search(name) for p in NON_GAME_PATTERNS)


def find_installed_games(steam_root):
    """Return {appid: name} for every installed game across all library folders."""
    games = {}
    library_dirs = [steam_root / "steamapps"]

    lib_doc = load_vdf(steam_root / "steamapps" / "libraryfolders.vdf")
    for _, entry in lib_doc.get("libraryfolders", {}).items():
        if isinstance(entry, dict) and entry.get("path"):
            library_dirs.append(Path(entry["path"]) / "steamapps")

    for lib in library_dirs:
        if not lib.is_dir():
            continue
        for manifest in lib.glob("appmanifest_*.acf"):
            state = load_vdf(manifest).get("AppState", {})
            appid = state.get("appid")
            name = state.get("name")
            if appid and name and is_probably_game(name):
                games[str(appid)] = name
    return games


def find_recent_user_id(steam_root):
    users = load_vdf(steam_root / "config" / "loginusers.vdf").get("users", {})
    best_id, best_ts = None, -1
    for steamid64, info in users.items():
        if not isinstance(info, dict):
            continue
        if info.get("mostrecent") == "1":
            return steamid64
        ts = int(info.get("Timestamp", 0) or 0)
        if ts > best_ts:
            best_ts, best_id = ts, steamid64
    return best_id


def load_playtime(steam_root, steamid64):
    """Returns {appid: {"last_played": ts, "playtime_2wks": minutes}}"""
    if not steamid64:
        return {}
    accountid = int(steamid64) & 0xFFFFFFFF
    local_cfg = steam_root / "userdata" / str(accountid) / "config" / "localconfig.vdf"
    doc = load_vdf(local_cfg)
    try:
        apps = doc["UserLocalConfigStore"]["Software"]["Valve"]["Steam"]["apps"]
    except (KeyError, TypeError):
        return {}

    out = {}
    for appid, entry in apps.items():
        if not isinstance(entry, dict):
            continue
        out[appid] = {
            "last_played": int(entry.get("LastPlayed", 0) or 0),
            "playtime_2wks": int(entry.get("Playtime2wks", 0) or 0),
        }
    return out


def compute_weight(info, now):
    """Baseline weight of 1 for every installed game, boosted heavily for
    anything played in the last ~30 days and further by 2-week playtime."""
    if not info:
        return 1.0
    last_played = info.get("last_played", 0)
    playtime_2wks = info.get("playtime_2wks", 0)
    days_since = (now - last_played) / 86400.0 if last_played > 0 else 3650.0
    recency = max(0.0, 30.0 - days_since) * 2.0
    weight = 1.0 + recency + playtime_2wks * 0.5
    return round(weight, 2)


def main():
    top_n = None
    if "--top" in sys.argv:
        i = sys.argv.index("--top")
        top_n = int(sys.argv[i + 1]) if i + 1 < len(sys.argv) else 5

    steam_root = find_steam_root()
    if not steam_root:
        if top_n is None:
            print(json.dumps([]))
        sys.stderr.write("revolver-scan-steam: could not find a Steam install\n")
        return 1

    games = find_installed_games(steam_root)
    if not games:
        if top_n is None:
            print(json.dumps([]))
        sys.stderr.write("revolver-scan-steam: no installed games found\n")
        return 1

    steamid64 = find_recent_user_id(steam_root)
    playtime = load_playtime(steam_root, steamid64)
    now = time.time()

    out = [
        {"appid": int(appid), "name": name, "weight": compute_weight(playtime.get(appid), now)}
        for appid, name in games.items()
    ]
    out.sort(key=lambda g: g["weight"], reverse=True)

    if top_n is not None:
        for g in out[:top_n]:
            print("   {:>7.1f}  {}".format(g["weight"], g["name"]))
    else:
        print(json.dumps(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
