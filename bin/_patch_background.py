#!/usr/bin/env python3
"""Idempotently wires RevolverBarrel into Background.qml's WidgetCanvas.

Handles these starting states, converging on the same result:
  - nothing installed yet -> fresh insert
  - the very first unconditional block (pre-settings-integration) -> upgrade
  - the intermediate config-gated but anchors-based block (positions wrong,
    since anchors inside a Loader.sourceComponent resolve against the
    Loader's own tiny bounds, not the screen) -> upgrade
  - the bgRoot.screen-positioned block, possibly with a stale corner
    margin and/or missing the newer source/steamMode bindings -> surgical
    in-place touch-ups (regex substitutions, not a wholesale block
    replace) so hand edits to the rest of the block survive a re-run

All paths converge on the same fully-current block: bgRoot.screen-based
positioning, current MARGIN, and chamberCount/fireAnimationEnabled/
source/steamMode all bound to Config.options.
"""
import re
import shutil
import sys

MARGIN = 80  # distance in px from the screen edge; was 48, felt jammed in the corner

path = sys.argv[1]
text = open(path).read()

NEW_BLOCK = '''                FadeLoader {
                    shown: Config.options.background.widgets.revolver.enable
                    sourceComponent: RevolverBarrel {
                        x: bgRoot.screen.width - width - %(m)d
                        y: bgRoot.screen.height - height - %(m)d
                        chamberCount: Config.options.background.widgets.revolver.chamberCount
                        fireAnimationEnabled: Config.options.background.widgets.revolver.fireAnimation
                        source: Config.options.background.widgets.revolver.source
                        steamMode: Config.options.background.widgets.revolver.steamMode
                    }
                }''' % {"m": MARGIN}

OLD_ANCHORS_BLOCK = '''                FadeLoader {
                    shown: Config.options.background.widgets.revolver.enable
                    sourceComponent: RevolverBarrel {
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        anchors.margins: 48
                        chamberCount: Config.options.background.widgets.revolver.chamberCount
                        fireAnimationEnabled: Config.options.background.widgets.revolver.fireAnimation
                    }
                }'''

OLD_UNCONDITIONAL_BLOCK = '''                RevolverBarrel {
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.margins: 48
                }'''

FIRE_ANIM_LINE_RE = re.compile(
    r"( *)fireAnimationEnabled: Config\.options\.background\.widgets\.revolver\.fireAnimation\n"
)
X_RE = re.compile(r"x: bgRoot\.screen\.width - width - (\d+)")
Y_RE = re.compile(r"y: bgRoot\.screen\.height - height - (\d+)")

changed_pieces = []  # human-readable list of what this run actually touched


def has_source_binding(t):
    return "Config.options.background.widgets.revolver.source" in t


# --- wholesale upgrades from older shapes of the block --------------------
if OLD_UNCONDITIONAL_BLOCK in text:
    shutil.copy(path, path + ".bak")
    text = text.replace(OLD_UNCONDITIONAL_BLOCK, NEW_BLOCK, 1)
    open(path, "w").write(text)
    print("UPGRADED_UNCONDITIONAL")
    sys.exit(0)

if OLD_ANCHORS_BLOCK in text:
    shutil.copy(path, path + ".bak")
    text = text.replace(OLD_ANCHORS_BLOCK, NEW_BLOCK, 1)
    open(path, "w").write(text)
    print("UPGRADED_ANCHORS")
    sys.exit(0)

# --- already on the bgRoot.screen block: surgical touch-ups only ----------
if X_RE.search(text) is not None:
    working = text
    backed_up = False

    x_match = X_RE.search(working)
    if x_match is not None and int(x_match.group(1)) != MARGIN:
        if not backed_up:
            shutil.copy(path, path + ".bak")
            backed_up = True
        working = X_RE.sub("x: bgRoot.screen.width - width - %d" % MARGIN, working)
        working = Y_RE.sub("y: bgRoot.screen.height - height - %d" % MARGIN, working)
        changed_pieces.append("margin")

    if not has_source_binding(working):
        m = FIRE_ANIM_LINE_RE.search(working)
        if m is not None:
            if not backed_up:
                shutil.copy(path, path + ".bak")
                backed_up = True
            indent = m.group(1)
            insertion = (
                indent + "source: Config.options.background.widgets.revolver.source\n"
                + indent + "steamMode: Config.options.background.widgets.revolver.steamMode\n"
            )
            working = working[:m.end()] + insertion + working[m.end():]
            changed_pieces.append("source/steamMode bindings")
        else:
            # Block's been hand-edited enough that the anchor line is gone -
            # don't guess where to splice; leave it and say so instead of
            # risking corrupting the user's edits.
            if changed_pieces:
                open(path, "w").write(working)
                print("MARGIN_UPDATED_PROPERTIES_ANCHOR_NOT_FOUND")
            else:
                print("PROPERTIES_ANCHOR_NOT_FOUND")
            sys.exit(0)

    if not changed_pieces:
        print("SKIP")
        sys.exit(0)

    open(path, "w").write(working)
    if changed_pieces == ["margin"]:
        print("MARGIN_UPDATED")
    elif changed_pieces == ["source/steamMode bindings"]:
        print("PROPERTIES_ADDED")
    else:
        print("MARGIN_AND_PROPERTIES_UPDATED")
    sys.exit(0)

# --- nothing installed yet: fresh insert -----------------------------------
shutil.copy(path, path + ".bak")

if "qs.modules.revolverBarrel" not in text:
    lines = text.split("\n")
    import_line = None
    for i, line in enumerate(lines):
        if line.startswith("import "):
            import_line = i
    if import_line is not None:
        lines.insert(import_line + 1, "import qs.modules.revolverBarrel")
        text = "\n".join(lines)

lines = text.split("\n")
anchor_idx = None
for i, line in enumerate(lines):
    if "wallpaperSafetyTriggered: bgRoot.wallpaperSafetyTriggered" in line:
        anchor_idx = i
        break
if anchor_idx is None:
    print("ANCHOR_NOT_FOUND")
    sys.exit(1)

# anchor_idx is 0-indexed; matches the "insert after 1-indexed line
# (anchor_idx+1)+2" logic the original bash/sed version used.
insert_at = anchor_idx + 3
new_lines = lines[:insert_at] + [""] + NEW_BLOCK.split("\n") + lines[insert_at:]
open(path, "w").write("\n".join(new_lines))
print("FRESH_INSERT")
