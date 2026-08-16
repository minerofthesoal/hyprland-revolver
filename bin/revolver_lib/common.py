"""
revolver_lib.common

Shared helpers used by every scan backend (steam.py, prismlauncher.py,
multimc.py) and by both entry points (revolver-scan, revolver-configure):

  - locating + reading ii's own config.json (single source of truth for
    which source/mode is active and the manual allow-list — no separate
    config file, so the Settings panel, revolver-configure, and hand
    edits all agree)
  - the recency/playtime/completion curves used by "recommended" mode,
    kept here so every source scores itself the same way and so there's
    one place to tune the shape of the curve

Nothing in here talks to Steam/Prism/MultiMC directly - that's in the
per-source modules.
"""
import configparser
import json
import os
import time
from pathlib import Path

# ii persists its whole config (background widgets, bar, AI settings, all
# of it) as one JSON file at $XDG_CONFIG_HOME/illogical-impulse/config.json
# - see Directories.qml's shellConfig/shellConfigPath. Config.options.* in
# QML maps 1:1 onto this file's top-level keys, so
# Config.options.background.widgets.revolver.source in the Settings panel
# is exactly background.widgets.revolver.source below.
def ii_config_path():
    override = os.environ.get("HYPRLAND_REVOLVER_CONFIG")
    if override:
        return Path(override).expanduser()
    xdg_config = os.environ.get("XDG_CONFIG_HOME") or "~/.config"
    return Path(xdg_config).expanduser() / "illogical-impulse" / "config.json"


_DEFAULT_REVOLVER_CONFIG = {
    "source": "steam",              # "steam" | "prismlauncher" | "multimc"
    "steamMode": "recent",          # "recent" | "random" | "recommended"
    "manualSelectionOnly": False,
    "manualSelection": [],          # list of ids (appid strings, or instance folder names)
}


def load_revolver_config():
    """Read background.widgets.revolver.* out of ii's config.json. Missing
    file / missing keys / unparsable JSON all degrade to defaults rather
    than erroring - a broken or absent ii config shouldn't stop the
    scanner from printing *something* for the widget to chamber."""
    cfg = dict(_DEFAULT_REVOLVER_CONFIG)
    path = ii_config_path()
    try:
        data = json.loads(path.read_text())
        revolver = data.get("background", {}).get("widgets", {}).get("revolver", {})
        if isinstance(revolver, dict):
            for key in _DEFAULT_REVOLVER_CONFIG:
                if key in revolver:
                    cfg[key] = revolver[key]
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        pass
    # Defensive type-narrowing - a hand-edited config.json shouldn't be
    # able to crash the scanner just because a field has the wrong type.
    if not isinstance(cfg.get("manualSelection"), list):
        cfg["manualSelection"] = []
    cfg["manualSelection"] = [str(x) for x in cfg["manualSelection"]]
    cfg["source"] = str(cfg.get("source") or "steam")
    cfg["steamMode"] = str(cfg.get("steamMode") or "recent")
    cfg["manualSelectionOnly"] = bool(cfg.get("manualSelectionOnly"))
    return cfg


def save_revolver_config(patch):
    """Read-modify-write background.widgets.revolver.* in ii's config.json,
    leaving every other key in the file untouched. Written atomically
    (temp file + rename) so a crash mid-write can't corrupt the rest of
    the user's ii config. Quickshell's Config.qml watches this file
    (FileView.watchChanges) and reloads on change, so edits made here
    (e.g. from revolver-configure) show up live without restarting
    quickshell."""
    path = ii_config_path()
    try:
        data = json.loads(path.read_text())
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        data = {}
    if not isinstance(data, dict):
        data = {}

    background = data.setdefault("background", {})
    if not isinstance(background, dict):
        background = {}
        data["background"] = background
    widgets = background.setdefault("widgets", {})
    if not isinstance(widgets, dict):
        widgets = {}
        background["widgets"] = widgets
    revolver = widgets.setdefault("revolver", {})
    if not isinstance(revolver, dict):
        revolver = {}
        widgets["revolver"] = revolver

    revolver.update(patch)

    path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = path.with_suffix(path.suffix + ".tmp")
    tmp_path.write_text(json.dumps(data, indent=4))
    tmp_path.replace(path)


# --------------------------------------------------------------------
# Weighting curves shared by every "recommended" scorer. Everything here
# is deliberately just a function of (days_since_last_played,
# playtime_hours, achievement_ratio) so steam.py / prismlauncher.py /
# multimc.py can all reuse the exact same shape instead of drifting.
# Tweak the constants below to change how "recommended" mode feels.
# --------------------------------------------------------------------

# Recency is intentionally U-shaped rather than "more recent = better":
# a game you played yesterday is an easy, low-friction rec (you're
# clearly mid-way through something), and a game you haven't touched in
# over a year is *also* a good rec (it's basically new again, and if you
# own it you probably meant to get back to it). The dead zone is the
# middle distance - a game from 2-3 months ago is neither a fresh session
# nor a forgotten one, so it scores lowest.
RECENT_WINDOW_DAYS = 14        # played within this -> strong "pick up where you left off" bonus
RECENT_BONUS = 3.0
STALE_THRESHOLD_DAYS = 365     # untouched longer than this -> "worth revisiting" bonus
STALE_BONUS = 2.5
NEVER_PLAYED_BONUS = 1.5       # installed but no recorded playtime at all - still eligible, modest bonus
MIDDLE_FLOOR = 0.2             # the dead zone never drops to literal zero odds

# Playtime is a much gentler signal than recency - total hours sunk into
# something correlates with "you like this", but shouldn't be able to
# dominate the roll on its own (a 400-hour game shouldn't crowd out
# everything else every single time).
PLAYTIME_WEIGHT_PER_HOUR = 0.15
PLAYTIME_WEIGHT_CAP = 6.0

# Achievement completion: a light bell curve peaking around "partway
# through" (nudges you back to finish something you've started) and
# tapering off at both 0% (never started - no signal either way) and
# 100% (already done - nothing left to nudge toward). Kept as a small
# accent on top of the recency/playtime signal, not a dominant factor,
# since local achievement data is best-effort (see steam.py) and often
# just won't be available.
ACHIEVEMENT_BONUS_MAX = 1.5
ACHIEVEMENT_SWEET_SPOT = 0.5  # ratio (achieved / total) that scores highest


def recency_component(days_since_last_played):
    """days_since_last_played: float, or None if there's no play record
    at all (installed but apparently never launched)."""
    if days_since_last_played is None:
        return NEVER_PLAYED_BONUS
    if days_since_last_played <= RECENT_WINDOW_DAYS:
        # fades from RECENT_BONUS down to ~0 across the recent window,
        # so "yesterday" beats "13 days ago" without a hard cliff
        return RECENT_BONUS * (1.0 - days_since_last_played / RECENT_WINDOW_DAYS)
    if days_since_last_played >= STALE_THRESHOLD_DAYS:
        # ramps up the longer it's been, capped so a 10-year-old game
        # doesn't run away with an enormous score
        over = min(days_since_last_played - STALE_THRESHOLD_DAYS, STALE_THRESHOLD_DAYS)
        return STALE_BONUS * (0.5 + 0.5 * (over / STALE_THRESHOLD_DAYS))
    return MIDDLE_FLOOR


def playtime_component(total_hours):
    if not total_hours or total_hours <= 0:
        return 0.0
    return min(PLAYTIME_WEIGHT_CAP, total_hours * PLAYTIME_WEIGHT_PER_HOUR)


def achievement_component(achieved, total):
    """achieved/total: ints, or None if unavailable (see steam.py's
    best-effort local achievement reader) - unavailable data contributes
    nothing rather than being guessed at."""
    if not total or achieved is None:
        return 0.0
    ratio = max(0.0, min(1.0, achieved / total))
    # triangular bump centered on ACHIEVEMENT_SWEET_SPOT, 0 at the edges
    if ratio <= ACHIEVEMENT_SWEET_SPOT:
        t = ratio / ACHIEVEMENT_SWEET_SPOT if ACHIEVEMENT_SWEET_SPOT else 0
    else:
        t = (1.0 - ratio) / (1.0 - ACHIEVEMENT_SWEET_SPOT)
    return ACHIEVEMENT_BONUS_MAX * max(0.0, t)


def recommended_weight(days_since_last_played, total_hours, achieved=None, total_achievements=None):
    weight = 1.0  # baseline floor, same philosophy as the "recent" curve: nothing ever hits zero
    weight += recency_component(days_since_last_played)
    weight += playtime_component(total_hours)
    weight += achievement_component(achieved, total_achievements)
    return round(weight, 2)


def apply_manual_selection(pool, cfg):
    """If manual curation is on, filter the pool down to just the
    selected ids (matched by id, case-insensitively by name as a
    fallback for hand-typed entries). Falls back to the unfiltered pool
    if the selection is empty or matches nothing, so a stale/typo'd
    manual list can't zero out the drum entirely."""
    if not cfg.get("manualSelectionOnly") or not cfg.get("manualSelection"):
        return pool
    wanted_ids = {s.strip() for s in cfg["manualSelection"] if s.strip()}
    wanted_names = {s.strip().lower() for s in wanted_ids}
    filtered = [
        g for g in pool
        if str(g.get("id")) in wanted_ids or str(g.get("name", "")).strip().lower() in wanted_names
    ]
    return filtered if filtered else pool


def now_ts():
    return time.time()


def read_instance_cfg(cfg_path):
    """PrismLauncher/MultiMC's instance.cfg is Qt QSettings' IniFormat,
    which - unlike a strict INI file - doesn't require a leading section
    header. Handle both: try as-is first, and if that fails (no section
    headers at all), retry with a synthetic [General] header prepended
    so configparser doesn't choke on bare key=value lines. Returns a
    plain dict of the [General] section (lowercased keys, same as
    configparser's default), or {} if the file can't be made sense of."""
    raw = cfg_path.read_text(errors="ignore")
    parser = configparser.ConfigParser(strict=False)
    try:
        parser.read_string(raw)
    except configparser.MissingSectionHeaderError:
        parser = configparser.ConfigParser(strict=False)
        parser.read_string("[General]\n" + raw)

    if parser.has_section("General"):
        section = "General"
    elif parser.sections():
        section = parser.sections()[0]
    else:
        return {}
    return dict(parser.items(section))
