#!/usr/bin/env python3
"""Idempotently wires RevolverBarrel into Background.qml's WidgetCanvas.

Handles four possible starting states, converging on the same result:
  - nothing installed yet -> fresh insert
  - the very first unconditional block (pre-settings-integration) -> upgrade
  - the intermediate config-gated but anchors-based block (positions wrong,
    since anchors inside a Loader.sourceComponent resolve against the
    Loader's own tiny bounds, not the screen) -> upgrade
  - the previous bgRoot.screen block but with a stale corner margin ->
    margin sync (doesn't touch anything else, so hand edits to the rest of
    the block survive a re-run)

All four converge on the current block, which positions explicitly via
bgRoot.screen instead of anchors.
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

X_RE = re.compile(r"x: bgRoot\.screen\.width - width - (\d+)")
Y_RE = re.compile(r"y: bgRoot\.screen\.height - height - (\d+)")

_x_match = X_RE.search(text)
if _x_match is not None:
    if int(_x_match.group(1)) == MARGIN:
        print("SKIP")
        sys.exit(0)
    shutil.copy(path, path + ".bak")
    text = X_RE.sub("x: bgRoot.screen.width - width - %d" % MARGIN, text)
    text = Y_RE.sub("y: bgRoot.screen.height - height - %d" % MARGIN, text)
    open(path, "w").write(text)
    print("MARGIN_UPDATED")
    sys.exit(0)

shutil.copy(path, path + ".bak")

if OLD_ANCHORS_BLOCK in text:
    text = text.replace(OLD_ANCHORS_BLOCK, NEW_BLOCK, 1)
    open(path, "w").write(text)
    print("UPGRADED_ANCHORS")
    sys.exit(0)

if OLD_UNCONDITIONAL_BLOCK in text:
    text = text.replace(OLD_UNCONDITIONAL_BLOCK, NEW_BLOCK, 1)
    open(path, "w").write(text)
    print("UPGRADED_UNCONDITIONAL")
    sys.exit(0)

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
