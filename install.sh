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

LIB_DIR="$HOME/.local/share/hyprland-revolver/lib"

mkdir -p "$MODULE_DIR" "$BIN_DIR" "$LIB_DIR"

# --- clean up the pre-multi-source single-script install, if present ---
if [ -f "$BIN_DIR/revolver-scan-steam" ]; then
    rm -f "$BIN_DIR/revolver-scan-steam"
    echo "-> removed old $BIN_DIR/revolver-scan-steam (replaced by revolver-scan)"
fi

rm -rf "$LIB_DIR/revolver_lib"
cp -r "$SRC_DIR/bin/revolver_lib" "$LIB_DIR/revolver_lib"

install -m 755 "$SRC_DIR/bin/revolver-scan" "$BIN_DIR/revolver-scan"
install -m 755 "$SRC_DIR/bin/revolver-configure" "$BIN_DIR/revolver-configure"
sed -i "s#__LIB_DIR__#$LIB_DIR#g" "$BIN_DIR/revolver-scan" "$BIN_DIR/revolver-configure"
echo "-> installed $BIN_DIR/revolver-scan and $BIN_DIR/revolver-configure (library: $LIB_DIR/revolver_lib)"

sed "s#__SCRIPT_PATH__#$BIN_DIR/revolver-scan#g" \
    "$SRC_DIR/qml/RevolverBarrel.qml" > "$MODULE_DIR/RevolverBarrel.qml"
echo "-> widget file installed: $MODULE_DIR/RevolverBarrel.qml"

# --- clean up the older standalone-window approach, if present ---
if grep -q "qs.modules.revolverBarrel" "$SHELL_FILE" 2>/dev/null; then
    cp "$SHELL_FILE" "$SHELL_FILE.bak"
    sed -i '/import qs\.modules\.revolverBarrel/d; /^\s*RevolverBarrel {}\s*$/d' "$SHELL_FILE"
    echo "-> removed old standalone RevolverBarrel {} from shell.qml (backup: shell.qml.bak)"
fi

# --- 1. Config.qml: add the revolver schema entry (enable, chamberCount,
#        fireAnimation, source, steamMode, manualSelectionOnly,
#        manualSelection) ---
if [ -f "$CONFIG_QML" ]; then
    cp "$CONFIG_QML" "$CONFIG_QML.bak"
    RESULT="$(python3 - "$CONFIG_QML" <<'PYEOF'
import sys
path = sys.argv[1]
text = open(path).read()
lines = text.split("\n")

NEW_FIELDS = [
    "enable",
    "chamberCount",
    "fireAnimation",
    "source",
    "steamMode",
    "manualSelectionOnly",
    "manualSelection",
]

# Already has every current field (possibly from a previous run of this
# same installer version) - nothing to do.
if "property JsonObject revolver: JsonObject" in text and all(
    ("property bool enable" in text if f == "enable" else
     "property int chamberCount" in text if f == "chamberCount" else
     "property bool fireAnimation" in text if f == "fireAnimation" else
     "property string source" in text if f == "source" else
     "property string steamMode" in text if f == "steamMode" else
     "property bool manualSelectionOnly" in text if f == "manualSelectionOnly" else
     "property list<string> manualSelection" in text)
    for f in NEW_FIELDS
):
    print("SKIP")
    sys.exit(0)

if "property JsonObject revolver: JsonObject" in text:
    # Existing (older) block - find it and surgically add whatever
    # fields it's missing, right before its closing brace, rather than
    # touching lines a user might have hand-edited (e.g. a changed
    # default chamberCount).
    block_idx = None
    for i, line in enumerate(lines):
        if "property JsonObject revolver: JsonObject" in line:
            block_idx = i
            break
    indent = lines[block_idx][:len(lines[block_idx]) - len(lines[block_idx].lstrip())]
    inner = indent + "    "
    depth = 0
    close_idx = None
    for i in range(block_idx, len(lines)):
        depth += lines[i].count("{") - lines[i].count("}")
        if depth == 0 and i > block_idx:
            close_idx = i
            break
    if close_idx is None:
        print("CLOSE_NOT_FOUND")
        sys.exit(1)

    additions = []
    if "property string source" not in text:
        additions.append(inner + 'property string source: "steam" // "steam", "prismlauncher", "multimc"')
    if "property string steamMode" not in text:
        additions.append(inner + 'property string steamMode: "recent" // "recent", "random", "recommended"')
    if "property bool manualSelectionOnly" not in text:
        additions.append(inner + "property bool manualSelectionOnly: false")
    if "property list<string> manualSelection" not in text:
        additions.append(inner + "property list<string> manualSelection: [] // ids/instance names; edit via revolver-configure")
    if not additions:
        print("SKIP")
        sys.exit(0)

    new_lines = lines[:close_idx] + additions + lines[close_idx:]
    open(path, "w").write("\n".join(new_lines))
    print("FIELDS_ADDED")
    sys.exit(0)

# No revolver block at all yet - fresh insert next to weather, same as
# every other background widget's schema entry.
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
    inner + 'property string source: "steam" // "steam", "prismlauncher", "multimc"',
    inner + 'property string steamMode: "recent" // "recent", "random", "recommended"',
    inner + "property bool manualSelectionOnly: false",
    inner + "property list<string> manualSelection: [] // ids/instance names; edit via revolver-configure",
    indent + "}",
]
new_lines = lines[:close_idx + 1] + block + lines[close_idx + 1:]
open(path, "w").write("\n".join(new_lines))
print("FRESH_INSERT")
PYEOF
)"
    case "$RESULT" in
        SKIP)
            echo "-> Config.qml already has the current revolver schema, skipping"
            ;;
        FIELDS_ADDED)
            echo "-> added new revolver fields (source/steamMode/manual selection) to Config.qml (backup: Config.qml.bak)"
            ;;
        FRESH_INSERT)
            echo "-> patched Config.qml (backup: Config.qml.bak)"
            ;;
        *)
            echo "!! Config.qml patch failed ($RESULT) - restoring backup"
            cp "$CONFIG_QML.bak" "$CONFIG_QML"
            ;;
    esac
else
    echo "!! Config.qml not found at $CONFIG_QML - skipping schema patch"
fi

# --- 2. BackgroundConfig.qml: add the Settings panel section (Enable,
#        Chambers, Fire animation, Source, and - only while source is
#        Steam - the recent/random/recommended mode picker) ---
if [ -f "$SETTINGS_QML" ]; then
    cp "$SETTINGS_QML" "$SETTINGS_QML.bak"
    RESULT="$(python3 - "$SETTINGS_QML" <<'PYEOF'
import sys
path = sys.argv[1]
text = open(path).read()
lines = text.split("\n")

SOURCE_SELECTOR_MARKER = "Config.options.background.widgets.revolver.source"

SELECTOR_BLOCK_TEMPLATE = """{inner}ConfigSelectionArray {{
{inner}    currentValue: Config.options.background.widgets.revolver.source
{inner}    onSelected: newValue => {{
{inner}        Config.options.background.widgets.revolver.source = newValue;
{inner}    }}
{inner}    options: [
{inner}        {{
{inner}            displayName: Translation.tr("Steam"),
{inner}            icon: "sports_esports",
{inner}            value: "steam"
{inner}        }},
{inner}        {{
{inner}            displayName: Translation.tr("PrismLauncher"),
{inner}            icon: "deployed_code",
{inner}            value: "prismlauncher"
{inner}        }},
{inner}        {{
{inner}            displayName: Translation.tr("MultiMC"),
{inner}            icon: "widgets",
{inner}            value: "multimc"
{inner}        }},
{inner}    ]
{inner}}}
{inner}ConfigSelectionArray {{
{inner}    visible: Config.options.background.widgets.revolver.source === "steam"
{inner}    currentValue: Config.options.background.widgets.revolver.steamMode
{inner}    onSelected: newValue => {{
{inner}        Config.options.background.widgets.revolver.steamMode = newValue;
{inner}    }}
{inner}    options: [
{inner}        {{
{inner}            displayName: Translation.tr("Recent"),
{inner}            icon: "history",
{inner}            value: "recent"
{inner}        }},
{inner}        {{
{inner}            displayName: Translation.tr("Random"),
{inner}            icon: "shuffle",
{inner}            value: "random"
{inner}        }},
{inner}        {{
{inner}            displayName: Translation.tr("Recommended"),
{inner}            icon: "auto_awesome",
{inner}            value: "recommended"
{inner}        }},
{inner}    ]
{inner}}}
{inner}StyledText {{
{inner}    font.pixelSize: Appearance.font.pixelSize.smaller
{inner}    color: Appearance.colors.colSubtext
{inner}    wrapMode: Text.WordWrap
{inner}    Layout.fillWidth: true
{inner}    text: Translation.tr("To hand-pick specific games/instances instead of scanning your whole library, run 'revolver-configure' in a terminal.")
{inner}}}"""

# Already fully up to date (possibly from a previous run of this exact
# installer version) - nothing to do.
if SOURCE_SELECTOR_MARKER in text:
    print("SKIP")
    sys.exit(0)

if "Widget: Revolver Barrel" in text:
    # Section already exists (from an older install) but predates the
    # source/mode selectors - find its closing brace and splice the new
    # controls in just before it, leaving the existing Enable/Chambers/
    # Fire animation controls (and any hand edits to them) untouched.
    title_idx = None
    for i, line in enumerate(lines):
        if 'title: Translation.tr("Widget: Revolver Barrel")' in line:
            title_idx = i
            break
    if title_idx is None:
        print("TITLE_NOT_FOUND")
        sys.exit(1)
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
    addition = SELECTOR_BLOCK_TEMPLATE.format(inner=inner).split("\n")
    new_lines = lines[:close_idx] + addition + lines[close_idx:]
    open(path, "w").write("\n".join(new_lines))
    print("SELECTORS_ADDED")
    sys.exit(0)

# No revolver section at all yet - fresh insert next to Weather, same
# anchor/backward-brace-walk the previous installer version used.
title_idx = None
for i, line in enumerate(lines):
    if 'title: Translation.tr("Widget: Weather")' in line:
        title_idx = i
        break
if title_idx is None:
    print("ANCHOR_NOT_FOUND")
    sys.exit(1)

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
] + SELECTOR_BLOCK_TEMPLATE.format(inner=inner).split("\n") + [
    indent + "}",
]
new_lines = lines[:close_idx + 1] + block + lines[close_idx + 1:]
open(path, "w").write("\n".join(new_lines))
print("FRESH_INSERT")
PYEOF
)"
    case "$RESULT" in
        SKIP)
            echo "-> BackgroundConfig.qml already has the current revolver section, skipping"
            ;;
        SELECTORS_ADDED)
            echo "-> added Source/Steam-mode selectors to the existing revolver section in BackgroundConfig.qml (backup: BackgroundConfig.qml.bak)"
            ;;
        FRESH_INSERT)
            echo "-> patched BackgroundConfig.qml (backup: BackgroundConfig.qml.bak)"
            ;;
        *)
            echo "!! BackgroundConfig.qml patch failed ($RESULT) - restoring backup"
            cp "$SETTINGS_QML.bak" "$SETTINGS_QML"
            ;;
    esac
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
    PROPERTIES_ADDED)
        echo "-> added source/steamMode bindings to the already-installed loader (backup: Background.qml.bak)"
        ;;
    MARGIN_AND_PROPERTIES_UPDATED)
        echo "-> updated the corner margin and added source/steamMode bindings on the already-installed loader (backup: Background.qml.bak)"
        ;;
    PROPERTIES_ANCHOR_NOT_FOUND)
        echo "!! Background.qml's revolver block looks hand-edited enough that I couldn't safely add"
        echo "   the new source/steamMode bindings - add them yourself (see README) or the Source/Mode"
        echo "   selectors in Settings won't do anything until you do."
        ;;
    MARGIN_UPDATED_PROPERTIES_ANCHOR_NOT_FOUND)
        echo "-> updated the corner margin (backup: Background.qml.bak), but couldn't safely add the new"
        echo "   source/steamMode bindings - the revolver block looks hand-edited. Add them yourself (see"
        echo "   README) or the Source/Mode selectors in Settings won't do anything until you do."
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
echo "Sanity-checking your configured source's scan (top 5 by weight):"
"$BIN_DIR/revolver-scan" --top 5 || echo "   (scan check failed - not fatal, install itself is done; see stderr above)"

cat <<'EOF'

Reload quickshell to see it (or restart it in the foreground to catch any
compile error live):

    pkill -f "qs -c ii"
    qs -c ii

It's toggleable and configurable from ii's own Settings panel (Super+I)
under Background -> "Widget: Revolver Barrel": Enable, Chambers, Fire
animation, and which source to chamber from (Steam / PrismLauncher /
MultiMC - Steam additionally gets a Recent/Random/Recommended mode
picker there too).

To hand-pick specific games/instances instead of scanning your whole
library, run:

    revolver-configure
EOF
