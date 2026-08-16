"""
revolver_lib.prismlauncher

Scans PrismLauncher instances and returns them in the same unified
{"id", "name", "weight", "launch"} schema the Steam backend uses.

Confirmed against PrismLauncher's own source (BaseInstance.cpp) and
official docs, not guessed:
  - instances live at ~/.local/share/PrismLauncher/instances/<id>/
    (id = the instance's directory name - id() literally returns
    QFileInfo(instanceRoot()).fileName(), and the official CLI docs
    confirm "the instance ID is typically the folder name")
  - each instance directory has an instance.cfg (Qt QSettings INI format,
    "[General]" section) with registerSetting()'d keys "name",
    "lastLaunchTime" (ms since epoch) and "totalTimePlayed" (seconds)
  - `prismlauncher --launch "<id>"` launches by that folder-name id
"""
import configparser
import time
from pathlib import Path

from . import common

INSTANCE_ROOTS = [
    "~/.local/share/PrismLauncher/instances",
    "~/.var/app/org.prismlauncher.PrismLauncher/data/PrismLauncher/instances",  # flatpak
]


def find_instances_root():
    for p in INSTANCE_ROOTS:
        path = Path(p).expanduser()
        if path.is_dir():
            return path
    return None


def scan():
    root = find_instances_root()
    if not root:
        return []

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
            "launch": ["prismlauncher", "--launch", instance_id],
        })
    out.sort(key=lambda g: g["weight"], reverse=True)
    return out
