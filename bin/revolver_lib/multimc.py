"""
revolver_lib.multimc

Scans MultiMC (the community MultiMC/Launcher fork, not PrismLauncher)
instances. instance.cfg uses the identical keys PrismLauncher does -
registerSetting("lastLaunchTime", ...) / registerSetting("totalTimePlayed",
...) are the same calls in both codebases' BaseInstance.cpp, PrismLauncher
having started as a fork of this project - so the scoring/parsing logic
is shared via common.read_instance_cfg().

What's genuinely best-effort here, unlike PrismLauncher, is *finding*
MultiMC at all: its AUR packaging is fragmented (the long-standing
multimc5 package is orphaned/deprecated in favor of PrismLauncher, and
the alternatives are inconsistent about install paths and binary names),
so both the data directory and the launch executable are resolved by
trying a short list of candidates rather than one known-good path.
"""
import configparser
import shutil
import time
from pathlib import Path

from . import common

INSTANCE_ROOTS = [
    "~/.local/share/multimc/instances",
    "~/.local/share/MultiMC/instances",
    "~/.var/app/org.multimc.MultiMC/data/multimc/instances",  # flatpak, if ever packaged
]

EXECUTABLE_CANDIDATES = ["multimc", "multimc5", "MultiMC"]


def find_instances_root():
    for p in INSTANCE_ROOTS:
        path = Path(p).expanduser()
        if path.is_dir():
            return path
    return None


def find_executable():
    for name in EXECUTABLE_CANDIDATES:
        found = shutil.which(name)
        if found:
            return name
    # Nothing on PATH - fall back to the most common name anyway so the
    # pool entry is at least self-explanatory if it fails to launch.
    return EXECUTABLE_CANDIDATES[0]


def scan():
    root = find_instances_root()
    if not root:
        return []

    executable = find_executable()
    now = time.time()
    out = []
    for entry in sorted(root.iterdir()):
        cfg_path = entry / "instance.cfg"
        if not entry.is_dir() or not cfg_path.is_file():
            continue
        try:
            fields = common.read_instance_cfg(cfg_path)
        except (OSError, configparser.Error):
            continue

        instance_id = entry.name
        name = fields.get("name") or instance_id

        last_launch_ms = int(fields.get("lastlaunchtime", 0) or 0)
        total_played_s = int(fields.get("totaltimeplayed", 0) or 0)

        days_since = None
        if last_launch_ms > 0:
            days_since = (now - last_launch_ms / 1000.0) / 86400.0
        total_hours = total_played_s / 3600.0

        weight = common.recommended_weight(days_since, total_hours)
        out.append({
            "id": instance_id,
            "name": name,
            "weight": weight,
            "launch": [executable, "--launch", instance_id],
        })
    out.sort(key=lambda g: g["weight"], reverse=True)
    return out
