# Revolver Barrel

A spinnable revolver desktop widget for illogical-impulse / Quickshell.
Lives bottom-right on your desktop, on every workspace, drawn over the
wallpaper - same mechanism as the built-in clock (it's a plain `Item`
inside `Background.qml`'s `WidgetCanvas`, not a separate window). The
dial itself reuses `MaterialCookie` and `StyledDropShadow` from
CookieClock.qml's own directory, so it shares the clock's wavy-edged,
drop-shadowed look.

Drag the drum to spin it. Each chamber is loaded from whichever source
you pick in Settings - your installed Steam library (weighted toward
what you've played recently, uniformly at random, or by a broader
"recommended" curve), your PrismLauncher instances, or your MultiMC
instances - and whatever chamber lands under the firing pin at top gets
launched. The chamber that fires visibly ejects its spent shell and
loads a fresh one before you can spin again.

## Install

### From the AUR

```sh
yay -S hyprland-revolver-git
hyprland-revolver-install
```

`pacman` drops the widget source and installer under
`/usr/share/hyprland-revolver/` and puts `hyprland-revolver-install` on
your `$PATH`. **`pacman -S`/`yay -S` will print a message telling you to
run that last command** - it can only ever stage files under `/usr`,
since it runs as root and never touches your `$HOME`, so that one step
genuinely can't be automated away. Run it as your normal user (not
root); it's the same `install.sh` below, just installed system-wide.

### From source

```sh
git clone https://github.com/minerofthesoal/hyprland-revolver.git
cd hyprland-revolver
./install.sh
```

Both paths run the same script. It reads Steam's/PrismLauncher's/
MultiMC's local files directly - no Steam Web API key needed. Backs up
every file it touches (`Background.qml`, `Config.qml`,
`BackgroundConfig.qml`, and `shell.qml` if it still has the older
standalone-window version) before patching, and is safe to re-run -
re-running after an update only patches in whatever's actually new and
leaves the rest (including any hand edits) alone.

## Choosing a source

Settings (Super+I) → Background → "Widget: Revolver Barrel" has a
Source picker: **Steam**, **PrismLauncher**, or **MultiMC**. Changing it
takes effect immediately, no reload needed.

- **Steam** additionally gets a mode picker - see "How the odds work"
  below.
- **PrismLauncher** scans `~/.local/share/PrismLauncher/instances/`
  (flatpak path too) and launches via `prismlauncher --launch <id>`.
  Recency/playtime come straight from each instance's `instance.cfg`
  (`lastLaunchTime`/`totalTimePlayed`), so the same "recommended"-style
  curve as Steam applies automatically - there's no separate mode picker
  for it, it's just always on for non-Steam sources.
- **MultiMC** works the same way, but is genuinely best-effort: the
  MultiMC AUR packaging situation is fragmented right now (the
  long-standing `multimc5` package is orphaned in favor of
  PrismLauncher), so both the instances directory and the launch
  executable are resolved by trying a short list of candidates rather
  than one known-good path. If it comes up empty, check
  `bin/revolver_lib/multimc.py`'s `INSTANCE_ROOTS`/
  `EXECUTABLE_CANDIDATES` for what it tried and adjust if your install
  doesn't match. PrismLauncher is the actively-maintained option if you
  have a choice.

## How the odds work

**Recent** (Steam's default): every installed game starts at weight `1`.
Games played in the last 30 days get `+2` per day of recency (so
yesterday >> 3 weeks ago), and 2-week playtime adds `+0.5` per minute on
top. Tweak in `bin/revolver_lib/steam.py:compute_weight_recent()`.

**Random**: every installed game gets the same weight. No bias at all.

**Recommended** (also what PrismLauncher/MultiMC always use): a broader
curve meant to surface either "pick up where you left off" *or*
"worth revisiting", not just whatever's most recent:

- Recency is **U-shaped**, not linear - a game from yesterday scores
  well, and so does one you haven't touched in over a year, but the
  months in between (recent enough to not feel forgotten, not recent
  enough to be "current") score lowest.
- Total playtime adds a gentle bonus - more hours sunk in is a soft
  signal you like it, capped so it can't dominate the roll on its own.
- Achievement completion adds a small bonus that peaks around being
  partway through (a nudge to finish something you started), tapering
  off at both 0% and 100%. This one's genuinely best-effort: Steam
  stores per-user achievement state in an undocumented local binary
  format that even dedicated Steam-file-parsing libraries leave as an
  open question, so it's read defensively and just contributes nothing
  if it can't be parsed on your Steam client version - see the big
  comment above `read_local_achievements()` in
  `bin/revolver_lib/steam.py` for specifics.

All three factors and their constants live in
`bin/revolver_lib/common.py` (`recency_component`, `playtime_component`,
`achievement_component`) - tweak the constants at the top of that file
to change how "recommended" feels.

Nothing ever hits weight zero in any mode - even an old, ignored game
can still get chambered, just rarely. Chambers are filled via weighted
sampling, but the drum still stops on one of them uniformly at random -
the bias only decides what's *loaded*, not where the wheel lands.

Changing the chamber count (Settings → Chambers, 4-12) reloads the drum
immediately to match. (Older versions of this widget had a bug here -
changing the count away from the default of 8 left the drum permanently
unable to fire, since nothing resynced the loaded chambers to the new
count. Fixed by `onChamberCountChanged` in `RevolverBarrel.qml`.)

## Manual selection

To hand-pick specific games/instances instead of scanning your whole
library/instance list, run:

```sh
revolver-configure
```

It's a small interactive terminal menu: change source/mode, flip manual
selection on, then check off exactly which entries should be eligible.
Everything it does writes straight to the same `config.json` the
Settings panel uses (`background.widgets.revolver.*`), so changes made
here show up live in the widget too - no restart needed, Quickshell
watches that file. Turning manual selection back off (or clearing the
list) goes back to scanning normally. A stale/empty manual list falls
back to the full library rather than showing nothing.

## Files

- `bin/revolver-scan` — entry point the widget calls; reads
  `background.widgets.revolver.*` out of ii's `config.json` and prints
  `[{id, name, weight, launch}, ...]` for whichever source/mode is
  configured. Also usable standalone: `revolver-scan --top 5`,
  `--source prismlauncher`, `--mode random`, etc.
- `bin/revolver-configure` — interactive terminal picker for manual
  game/instance selection (see above); also duplicates the source/mode
  toggles so it works without the Settings panel at all.
- `bin/revolver_lib/` — the actual scanning logic, one module per
  source (`steam.py`, `prismlauncher.py`, `multimc.py`) plus shared
  config I/O and weighting curves (`common.py`).
- `bin/_patch_background.py` — idempotently wires the widget into
  `Background.qml`.
- `qml/RevolverBarrel.qml` — the widget itself (a plain `Item`, themed
  with ii's own `Appearance.colors` tokens, dial shape from
  `MaterialCookie`).
- `install.sh` — installs everything above, patches `Config.qml` /
  `BackgroundConfig.qml` / `Background.qml`.
- `PKGBUILD` / `hyprland-revolver-git.install` — build the
  `hyprland-revolver-git` AUR package; the `.install` file is what
  prints the "now run `hyprland-revolver-install`" message after
  `pacman -S`. See "Publishing" below.
- `publish-aur.sh` — pushes the current `PKGBUILD`/`.install` to the
  AUR; see "Publishing" below.

## Customizing

- Chamber count: `chamberCount` property at the top of
  `RevolverBarrel.qml`, or the Settings spinner (live, no reload) - all
  the rotation/snapping math is derived from it, so changing it is safe
  (chamber circle size/orbit radius are still hand-tuned for around 8
  though, revisit those if you go much higher or lower).
- Shell look: each chamber's casing (brass rim, primer cap) is built
  from plain layered `Rectangle`s in the chamber `Repeater`'s delegate
  in `RevolverBarrel.qml` - no image assets, so recoloring or resizing
  it is just editing those `Rectangle`s in place. The eject/reload
  animation (`ejectReload` `SequentialAnimation`, same delegate) drives
  a separate inner `shell` `Item` via `transform: [Rotation, Translate]`
  so it can fall/tumble/fade independently of the chamber's fixed
  position on the drum.
- Position: bottom-right, `80`px in from the screen edge. Set via
  `MARGIN` at the top of `bin/_patch_background.py` — re-run
  `install.sh` after changing it, it'll sync an already-installed block
  instead of skipping. It's plain `x`/`y` off `bgRoot.screen`, not
  anchors — anchors inside a `Loader.sourceComponent` resolve against
  the Loader's own tiny bounds, not the screen, which is why the drum
  used to land in the top-left corner instead of the bottom-right.
  Search for `RevolverBarrel {` inside `Background.qml` if you want to
  hand-edit it directly.
- Colors pull from `Appearance.colors.colPrimaryContainer` /
  `colSecondary` / `colTertiary` / `colShadow`, matching the same
  palette CookieClock uses.
- Launch mechanism is source-specific and comes back from `revolver-scan`
  as a ready-to-run argv in each entry's `"launch"` field (`xdg-open
  steam://rungameid/<appid>` for Steam, `prismlauncher --launch <id>`
  for PrismLauncher, etc.) - `RevolverBarrel.qml`'s `_launchGame()` just
  runs whatever it's given, so adding a new source is a new module in
  `bin/revolver_lib/` plus a line in `revolver-scan`'s `SOURCES` dict,
  no QML changes needed.

## If your ii layout differs

`install.sh` anchors its patches on specific lines it expects to find in
`Config.qml`/`BackgroundConfig.qml`/`Background.qml` (from the stock
Weather/Clock widget blocks). If your fork doesn't match, the relevant
step backs out safely and tells you what it couldn't find. To wire the
widget into `Background.qml` by hand, drop this inside the existing
`WidgetCanvas { ... }` block, alongside the other `FadeLoader`s:

```qml
FadeLoader {
    shown: Config.options.background.widgets.revolver.enable
    sourceComponent: RevolverBarrel {
        x: bgRoot.screen.width - width - 80
        y: bgRoot.screen.height - height - 80
        chamberCount: Config.options.background.widgets.revolver.chamberCount
        fireAnimationEnabled: Config.options.background.widgets.revolver.fireAnimation
        source: Config.options.background.widgets.revolver.source
        steamMode: Config.options.background.widgets.revolver.steamMode
    }
}
```

`bgRoot` should be the `id` of `Background.qml`'s root `Item`/`Window`
(whatever exposes a `screen` property in your fork) — anchors don't work
here since this runs inside a `Loader.sourceComponent`, which has its
own tiny implicit bounds rather than the screen's.

Also add `import qs` (for the `GlobalStates` singleton the widget's
lock-safety bar and drag-to-spin depend on) and
`import qs.modules.revolverBarrel` near the top of the file. And in
`Config.qml`, next to the other `background.widgets.*` entries:

```qml
property JsonObject revolver: JsonObject {
    property bool enable: true
    property int chamberCount: 8
    property bool fireAnimation: true
    property string source: "steam" // "steam", "prismlauncher", "multimc"
    property string steamMode: "recent" // "recent", "random", "recommended"
    property bool manualSelectionOnly: false
    property list<string> manualSelection: [] // ids/instance names; edit via revolver-configure
}
```

## Publishing (maintainer notes)

This repo doubles as the AUR source — the `PKGBUILD` at the repo root
builds a `-git` package (`hyprland-revolver-git`) that clones this repo,
so there's nothing extra to keep in sync beyond bumping it after real
changes.

### 1. Push this repo to GitHub

```sh
cd hyprland-revolver
git init -b main            # skip if already a repo
git add .
git commit -m "Initial commit"
git remote add origin git@github.com:minerofthesoal/hyprland-revolver.git
git push -u origin main
```

Create the (empty) `hyprland-revolver` repo under your GitHub account
first (web UI, or
`gh repo create minerofthesoal/hyprland-revolver --public`) if it
doesn't exist yet.

### 2. Sanity-check the PKGBUILD locally

From a machine with an AUR helper's build tooling (`base-devel`, `git`):

```sh
makepkg -si          # builds + installs, asks for sudo to pacman -U at the end
```

If it builds cleanly, `pkgver()` correctly reports something like
`r1.abcdef0`, you see the post-install message telling you to run
`hyprland-revolver-install`, and running that actually wires the widget
in, you're ready to publish.

### 3. Set up AUR access (first time only)

1. Create an account at <https://aur.archlinux.org> if you don't have
   one.
2. Add an SSH key to your AUR account under **My Account → SSH Public
   Key**.
3. Point SSH at AUR for that key, e.g. in `~/.ssh/config`:
   ```
   Host aur.archlinux.org
       IdentityFile ~/.ssh/aur
       User aur
   ```

### 4. Publish the AUR package

Run this from the repo root, on an Arch machine, with the SSH key from
step 3 active:

```sh
./publish-aur.sh
```

It clones `ssh://aur@aur.archlinux.org/hyprland-revolver-git.git` (an
empty clone is normal and expected the very first time — AUR provisions
the real package on the *push*, not the clone), copies in the current
`PKGBUILD` and `hyprland-revolver-git.install`, generates a fresh
`.SRCINFO` via `makepkg`, commits, and pushes. It's a no-op if nothing
changed since the last run, so it's safe to re-run any time you touch
either file.

It needs your AUR SSH identity to do the actual push, which is exactly
why this has to run on your machine and not anywhere else. If it fails
partway through, here's the same thing by hand:

```sh
git clone ssh://aur@aur.archlinux.org/hyprland-revolver-git.git aur-hyprland-revolver-git
cp PKGBUILD hyprland-revolver-git.install aur-hyprland-revolver-git/
cd aur-hyprland-revolver-git
makepkg --printsrcinfo > .SRCINFO
git add PKGBUILD hyprland-revolver-git.install .SRCINFO
git commit -m "Initial import: hyprland-revolver-git"
git push
```

Either way, it'll show up at
`https://aur.archlinux.org/packages/hyprland-revolver-git` shortly after
the push.

### 5. Ship a later update

```sh
git add -A && git commit -m "..." && git push   # push the GitHub repo as usual
./publish-aur.sh                                 # re-run only if PKGBUILD/.install changed
```

Since `pkgver()` derives from `git rev-list`/`git rev-parse` against the
GitHub repo's history, users who reinstall or `-Syu` with an AUR helper
pick up new commits automatically — you don't need to bump anything by
hand unless `pkgrel` needs an unrelated packaging fix.
