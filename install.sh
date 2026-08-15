#!/usr/bin/env bash
# Installs the Revolver Barrel widget into an illogical-impulse (Quickshell)
# config: the widget itself, its Config.options schema entry, its Settings
# panel toggle, and its FadeLoader-gated instantiation in Background.qml.
set -euo pipefail

QS_DIR="${QUICKSHELL_CONFIG_DIR:-$HOME/.config/quickshell/ii}"
MODULE_DIR="$QS_DIR/modules/revolverBarrel"
BIN_DIR="$HOME/.local/bin"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BG_FILE="$QS_DIR/modules/ii/background/Background.qml"
SHELL_FILE="$QS_DIR/shell.qml"
CONFIG_QML="$QS_DIR/modules/common/Config.qml"
SETTINGS_QML="$QS_DIR/modules/settings/BackgroundConfig.qml"

echo "== Revolver Barrel installer =="

if [ ! -d "$QS_DIR" ]; then
    echo "!! No quickshell config found at: $QS_DIR"
    echo "   export QUICKSHELL_CONFIG_DIR=/path/to/your/ii and re-run."
    exit 1
fi
if [ ! -f "$BG_FILE" ]; then
    echo "!! Couldn't find Background.qml at: $BG_FILE"
    exit 1
fi

command -v python3 >/dev/null 2>&1 || { echo "!! python3 is required"; exit 1; }

mkdir -p "$MODULE_DIR" "$BIN_DIR"

install -m 755 "$SRC_DIR/bin/revolver_scan_steam.py" "$BIN_DIR/revolver-scan-steam"
sed "s#__SCRIPT_PATH__#$BIN_DIR/revolver-scan-steam#g" \
    "$SRC_DIR/qml/RevolverBarrel.qml" > "$MODULE_DIR/RevolverBarrel.qml"
echo "-> widget file installed: $MODULE_DIR/RevolverBarrel.qml"

# --- clean up the older standalone-window approach, if present ---
if grep -q "qs.modules.revolverBarrel" "$SHELL_FILE" 2>/dev/null; then
    cp "$SHELL_FILE" "$SHELL_FILE.bak"
    sed -i '/import qs\.modules\.revolverBarrel/d; /^\s*RevolverBarrel {}\s*$/d' "$SHELL_FILE"
    echo "-> removed old standalone RevolverBarrel {} from shell.qml (backup: shell.qml.bak)"
fi

# --- 1. Config.qml: add the revolver schema entry (enable, chamberCount) ---
if [ -f "$CONFIG_QML" ]; then
    if grep -q "property JsonObject revolver: JsonObject" "$CONFIG_QML"; then
        echo "-> Config.qml already has the revolver schema, skipping"
    else
        cp "$CONFIG_QML" "$CONFIG_QML.bak"
        if python3 - "$CONFIG_QML" <<'PYEOF'
import sys
path = sys.argv[1]
lines = open(path).read().split("\n")

anchor_idx = None
for i, line in enumerate(lines):
    if "property JsonObject weather: JsonObject {" in line:
        anchor_idx = i
        break
if anchor_idx is None:
    print("ANCHOR_NOT_FOUND")
    sys.exit(1)

indent = lines[anchor_idx][:len(lines[anchor_idx]) - len(lines[anchor_idx].lstrip())]
inner = indent + "    "

depth = 0
close_idx = None
for i in range(anchor_idx, len(lines)):
    depth += lines[i].count("{") - lines[i].count("}")
    if depth == 0 and i > anchor_idx:
        close_idx = i
        break
if close_idx is None:
    print("CLOSE_NOT_FOUND")
    sys.exit(1)

block = [
    indent + "property JsonObject revolver: JsonObject {",
    inner + "property bool enable: true",
    inner + "property int chamberCount: 8",
    inner + "property bool fireAnimation: true",
    indent + "}",
]
new_lines = lines[:close_idx + 1] + block + lines[close_idx + 1:]
open(path, "w").write("\n".join(new_lines))
print("PATCHED")
PYEOF
        then
            echo "-> patched Config.qml (backup: Config.qml.bak)"
        else
            echo "!! Config.qml patch failed - restoring backup"
            cp "$CONFIG_QML.bak" "$CONFIG_QML"
        fi
    fi
else
    echo "!! Config.qml not found at $CONFIG_QML - skipping schema patch"
fi

# --- 2. BackgroundConfig.qml: add the Settings panel toggle section ---
if [ -f "$SETTINGS_QML" ]; then
    if grep -q "Widget: Revolver Barrel" "$SETTINGS_QML"; then
        echo "-> BackgroundConfig.qml already has the revolver section, skipping"
    else
        cp "$SETTINGS_QML" "$SETTINGS_QML.bak"
        if python3 - "$SETTINGS_QML" <<'PYEOF'
import sys
path = sys.argv[1]
lines = open(path).read().split("\n")

title_idx = None
for i, line in enumerate(lines):
    if 'title: Translation.tr("Widget: Weather")' in line:
        title_idx = i
        break
if title_idx is None:
    print("ANCHOR_NOT_FOUND")
    sys.exit(1)

# walk backward to the enclosing "ContentSection {" line
start_idx = None
for i in range(title_idx, -1, -1):
    if lines[i].strip() == "ContentSection {":
        start_idx = i
        break
if start_idx is None:
    print("SECTION_START_NOT_FOUND")
    sys.exit(1)

indent = lines[start_idx][:len(lines[start_idx]) - len(lines[start_idx].lstrip())]
inner = indent + "    "

depth = 0
close_idx = None
for i in range(start_idx, len(lines)):
    depth += lines[i].count("{") - lines[i].count("}")
    if depth == 0 and i > start_idx:
        close_idx = i
        break
if close_idx is None:
    print("SECTION_END_NOT_FOUND")
    sys.exit(1)

block = [
    "",
    indent + "ContentSection {",
    inner + 'icon: "casino"',
    inner + 'title: Translation.tr("Widget: Revolver Barrel")',
    "",
    inner + "ConfigSwitch {",
    inner + '    buttonIcon: "check"',
    inner + '    text: Translation.tr("Enable")',
    inner + "    checked: Config.options.background.widgets.revolver.enable",
    inner + "    onCheckedChanged: {",
    inner + "        Config.options.background.widgets.revolver.enable = checked;",
    inner + "    }",
    inner + "}",
    inner + "ConfigSpinBox {",
    inner + '    icon: "casino"',
    inner + '    text: Translation.tr("Chambers")',
    inner + "    value: Config.options.background.widgets.revolver.chamberCount",
    inner + "    from: 4",
    inner + "    to: 12",
    inner + "    stepSize: 1",
    inner + "    onValueChanged: {",
    inner + "        Config.options.background.widgets.revolver.chamberCount = value;",
    inner + "    }",
    inner + "}",
    inner + "ConfigSwitch {",
    inner + '    buttonIcon: "local_fire_department"',
    inner + '    text: Translation.tr("Fire animation")',
    inner + "    checked: Config.options.background.widgets.revolver.fireAnimation",
    inner + "    onCheckedChanged: {",
    inner + "        Config.options.background.widgets.revolver.fireAnimation = checked;",
    inner + "    }",
    inner + "}",
    indent + "}",
]
new_lines = lines[:close_idx + 1] + block + lines[close_idx + 1:]
open(path, "w").write("\n".join(new_lines))
print("PATCHED")
PYEOF
        then
            echo "-> patched BackgroundConfig.qml (backup: BackgroundConfig.qml.bak)"
        else
            echo "!! BackgroundConfig.qml patch failed - restoring backup"
            cp "$SETTINGS_QML.bak" "$SETTINGS_QML"
        fi
    fi
else
    echo "!! BackgroundConfig.qml not found at $SETTINGS_QML - skipping settings-panel patch"
fi

# --- 3. Background.qml: FadeLoader-gated instantiation, positioned via
#        bgRoot.screen (not anchors, which don't work through a Loader) ---
PATCH_RESULT="$(python3 "$SRC_DIR/bin/_patch_background.py" "$BG_FILE")"
case "$PATCH_RESULT" in
    SKIP)
        echo "-> Background.qml already has the position-fixed loader, skipping"
        ;;
    MARGIN_UPDATED)
        echo "-> updated the corner margin on the already-installed loader (backup: Background.qml.bak)"
        ;;
    UPGRADED_ANCHORS)
        echo "-> fixed Background.qml's widget position (was anchoring against the Loader, not the screen) (backup: Background.qml.bak)"
        ;;
    UPGRADED_UNCONDITIONAL)
        echo "-> upgraded Background.qml's original unconditional widget straight to the position-fixed, config-gated loader (backup: Background.qml.bak)"
        ;;
    FRESH_INSERT)
        echo "-> inserted the position-fixed, config-gated widget into Background.qml"
        ;;
    ANCHOR_NOT_FOUND)
        echo "!! Couldn't find the expected anchor line in Background.qml - add the widget manually (see README)."
        ;;
    *)
        echo "!! Unexpected result patching Background.qml: $PATCH_RESULT"
        ;;
esac

echo
echo "Sanity-checking your Steam library scan (top 5 by weight):"
"$BIN_DIR/revolver-scan-steam" --top 5 || echo "   (scan check failed - not fatal, install itself is done; see stderr above)"

cat <<'EOF'

Reload quickshell to see it (or restart it in the foreground to catch any
compile error live):

    pkill -f "qs -c ii"
    qs -c ii

It's now toggleable and configurable from ii's own Settings panel (Super+I)
under Background -> "Widget: Revolver Barrel" - Enable switch and a
Chambers count spinner, same UI pattern as the Weather/Clock widgets.
EOF
