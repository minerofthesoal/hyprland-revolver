"""
revolver_lib.steam

Scans the local Steam library (no Web API key needed - same approach the
original script used) and returns a pool of installed games in the
unified {"id", "name", "weight", "launch"} schema every source module
emits, so the widget and revolver-scan don't need to know or care which
source produced a given entry.

Three modes (background.widgets.revolver.steamMode in ii's config.json,
or --mode on the CLI):

  recent       - the original behaviour: weight heavily toward whatever
                 you've played in the last ~30 days (see
                 compute_weight_recent).
  random       - every installed game gets the same weight; pure uniform
                 chance regardless of playtime/recency.
  recommended  - a broader curve (common.recommended_weight): favors
                 both "picking up where you left off" (played recently)
                 *and* "worth revisiting" (installed but untouched for
                 a year+), lightly boosted by total playtime and, when
                 available, how far into a game's achievements you are.
"""
import json
import re
import time
from pathlib import Path

from . import common

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
    """Returns {appid: {"last_played": ts, "playtime_2wks": minutes,
    "playtime_forever": minutes}}. The "Playtime" (lifetime minutes) key
    is undocumented, same as LastPlayed/Playtime2wks below - unlike
    those two though, some Steam client versions apparently don't
    populate it locally at all, so it's read best-effort and just
    defaults to 0 (meaning the playtime factor in "recommended" mode
    contributes nothing for that game, not that it's wrong)."""
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
            "playtime_forever": int(entry.get("Playtime", 0) or 0),
        }
    return out


# --------------------------------------------------------------------
# Best-effort local achievement reader.
#
# Steam stores per-user achievement state in a binary file per game at
# Steam/appcache/stats/UserGameStats_<accountid>_<appid>.bin. This format
# is *not* officially documented, and even dedicated Steam-file-parsing
# libraries leave it as an open question (the well-known `steamfiles`
# PyPI package lists "UserGameStats (achievements)" as an unimplemented
# TODO). What community reverse-engineering broadly agrees on is that it
# reuses the same generic binary KeyValues grammar Valve uses for
# appinfo.vdf/packageinfo.vdf/shortcuts.vdf (type-tagged nodes: 0x00
# nested object, 0x01 string, 0x02 int32, 0x07 uint64, 0x08 end-of-
# object), with an "achievements" section whose children are individual
# achievement records each carrying a "time" field (unix timestamp,
# nonzero if/when it was unlocked).
#
# Because none of that is Valve-documented, this reader fails closed:
# any structure that doesn't match cleanly - a parse error, an
# unexpected type byte, no achievements section found - returns None
# (meaning "unknown"), never a guessed or partial number. common.py's
# achievement_component() treats None as "contributes nothing to the
# score", so a Steam client version this doesn't work on just quietly
# loses that one small factor rather than skewing the recommendation.
# --------------------------------------------------------------------

_BVDF_OBJECT = 0x00
_BVDF_STRING = 0x01
_BVDF_INT32 = 0x02
_BVDF_FLOAT32 = 0x03
_BVDF_UINT64 = 0x07
_BVDF_OBJECT_END = 0x08


def _read_cstring(data, pos):
    end = data.index(b"\x00", pos)
    return data[pos:end].decode("utf-8", errors="replace"), end + 1


def _parse_binary_vdf_object(data, pos):
    obj = {}
    while True:
        if pos >= len(data):
            raise ValueError("truncated binary vdf")
        tag = data[pos]
        pos += 1
        if tag == _BVDF_OBJECT_END:
            return obj, pos
        name, pos = _read_cstring(data, pos)
        if tag == _BVDF_OBJECT:
            child, pos = _parse_binary_vdf_object(data, pos)
            obj[name] = child
        elif tag == _BVDF_STRING:
            val, pos = _read_cstring(data, pos)
            obj[name] = val
        elif tag == _BVDF_INT32 or tag == _BVDF_FLOAT32:
            obj[name] = int.from_bytes(data[pos:pos + 4], "little", signed=False)
            pos += 4
        elif tag == _BVDF_UINT64:
            obj[name] = int.from_bytes(data[pos:pos + 8], "little", signed=False)
            pos += 8
        else:
            raise ValueError("unrecognized binary vdf type tag %#x" % tag)
    # unreachable


def _find_achievements_section(node, depth=0):
    """Depth-first search for a nested object whose key looks like an
    achievements list (a dict of dicts, each with a "time"-ish field)."""
    if depth > 6 or not isinstance(node, dict):
        return None
    for key, val in node.items():
        if not isinstance(val, dict) or not val:
            continue
        if key.lower() in ("achievements", "achievement"):
            return val
        found = _find_achievements_section(val, depth + 1)
        if found is not None:
            return found
    return None


def read_local_achievements(steam_root, steamid64, appid):
    """Returns (achieved_count, total_count) or None if unavailable/unparsable."""
    if not steamid64:
        return None
    accountid = int(steamid64) & 0xFFFFFFFF
    stats_path = steam_root / "appcache" / "stats" / "UserGameStats_{}_{}.bin".format(accountid, appid)
    if not stats_path.is_file():
        return None
    try:
        data = stats_path.read_bytes()
        if len(data) < 2 or data[0] != _BVDF_OBJECT:
            return None
        _root_name, pos = _read_cstring(data, 1)
        tree, _ = _parse_binary_vdf_object(data, pos)
        section = _find_achievements_section(tree)
        if not section:
            return None
        total = len(section)
        if total == 0:
            return None
        achieved = 0
        for entry in section.values():
            if not isinstance(entry, dict):
                continue
            unlocked = False
            for k, v in entry.items():
                if "time" in k.lower() and isinstance(v, int) and v > 0:
                    unlocked = True
                    break
            if unlocked:
                achieved += 1
        return (achieved, total)
    except Exception:
        # Best-effort by design - see module docstring. Any failure here
        # means "we don't know", not "zero achievements".
        return None


def compute_weight_recent(info, now):
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


def compute_weight_recommended(info, now, steam_root, steamid64, appid):
    last_played = (info or {}).get("last_played", 0)
    days_since = (now - last_played) / 86400.0 if last_played > 0 else None
    total_hours = ((info or {}).get("playtime_forever", 0) or 0) / 60.0
    achievements = read_local_achievements(steam_root, steamid64, appid)
    achieved, total = achievements if achievements else (None, None)
    return common.recommended_weight(days_since, total_hours, achieved, total)


def scan(mode="recent"):
    """Returns a list of {"id", "name", "weight", "launch"} dicts, or []
    if no Steam install / library could be found."""
    steam_root = find_steam_root()
    if not steam_root:
        return []

    games = find_installed_games(steam_root)
    if not games:
        return []

    steamid64 = find_recent_user_id(steam_root)
    playtime = load_playtime(steam_root, steamid64)
    now = time.time()

    out = []
    for appid, name in games.items():
        if mode == "random":
            weight = 1.0
        elif mode == "recommended":
            weight = compute_weight_recommended(playtime.get(appid), now, steam_root, steamid64, appid)
        else:  # "recent" (default/fallback for unrecognized modes too)
            weight = compute_weight_recent(playtime.get(appid), now)
        out.append({
            "id": appid,
            "name": name,
            "weight": weight,
            "launch": ["xdg-open", "steam://rungameid/" + appid],
        })
    out.sort(key=lambda g: g["weight"], reverse=True)
    return out
