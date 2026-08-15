# Revolver Barrel

A spinnable 8-chamber revolver desktop widget for illogical-impulse /
Quickshell. Lives bottom-right on your desktop, on every workspace, drawn
over the wallpaper - same mechanism as the built-in clock (it's a plain
`Item` inside `Background.qml`'s `WidgetCanvas`, not a separate window).
The dial itself reuses `MaterialCookie` and `StyledDropShadow` from
CookieClock.qml's own directory, so it shares the clock's wavy-edged,
drop-shadowed look.

Drag the drum to spin it. It's loaded with 8 games sampled from your
installed Steam library (weighted toward what you've played recently / in
the last 2 weeks), and whatever chamber lands under the firing pin at top
gets launched.

## Install

### From the AUR

```sh
yay -S hyprland-revolver-git
hyprland-revolver-install
```

`pacman` drops the widget source and installer under
`/usr/share/hyprland-revolver/` and puts `hyprland-revolver-install` on your
`$PATH`. Run that as your normal user (not root) — it's the same
`install.sh` below, just installed system-wide. It still only ever touches
files under `$HOME`; the package itself doesn't and can't do that install
step for you, since it has to run as you, against your own Quickshell
config, after `pacman` is done.

### From source

```sh
git clone https://github.com/minerofthesoal/hyprland-revolver.git
cd hyprland-revolver
./install.sh
```

Both paths run the same script. It reads Steam's local VDF files directly —
no Steam Web API key needed. Backs up `Background.qml` (and `shell.qml`, if
it still has the older standalone-window version) before patching, and is
safe to re-run.

## How the odds work

Every installed game starts at weight `1`. Games played in the last 30 days
get `+2` per day of recency (so yesterday >> 3 weeks ago), and 2-week
playtime adds `+0.5` per minute on top. Nothing ever hits zero — old,
unplayed games can still get chambered, just rarely. Tweak the curve in
`bin/revolver_scan_steam.py:compute_weight()`.

The 8 physical chambers are filled via weighted sampling, but the drum still
stops on one of the 8 uniformly at random — the bias only decides what's
*loaded*, not where the wheel lands.

## Files

- `bin/revolver_scan_steam.py` — scans Steam, prints `[{appid, name, weight}, ...]`
- `qml/RevolverBarrel.qml` — the widget itself (a plain `Item`, themed with
  ii's own `Appearance.colors` tokens, dial shape from `MaterialCookie`)
- `install.sh` — installs the scanner, wires the widget into
  `Background.qml`'s `WidgetCanvas`
- `PKGBUILD` — builds the `hyprland-revolver-git` AUR package (ships this repo
  under `/usr/share/hyprland-revolver` plus a `hyprland-revolver-install`
  wrapper on `$PATH`; see "Publishing" below)

## Customizing

- Chamber count: `chamberCount` property at the top of `RevolverBarrel.qml`
  — all the rotation/snapping math is derived from it, so changing it is
  safe (chamber circle size/orbit radius are still hand-tuned for 8 though,
  revisit those if you go much higher or lower).
- Position: bottom-right, `80`px in from the screen edge. Set via `MARGIN`
  at the top of `bin/_patch_background.py` — re-run `install.sh` after
  changing it, it'll sync an already-installed block instead of skipping.
  It's plain `x`/`y` off `bgRoot.screen`, not anchors — anchors inside a
  `Loader.sourceComponent` resolve against the Loader's own tiny bounds,
  not the screen, which is why the drum used to land in the top-left
  corner instead of the bottom-right. Search for `RevolverBarrel {` inside
  `Background.qml` if you want to hand-edit it directly.
- Colors pull from `Appearance.colors.colPrimaryContainer` /
  `colSecondary` / `colTertiary` / `colShadow`, matching the same palette
  CookieClock uses.
- Launch mechanism is `xdg-open steam://rungameid/<appid>` — swap for
  `steam -applaunch <appid>` in `launchProc.command` if you'd rather shell
  out to the Steam binary directly.

## If your ii layout differs

`install.sh` anchors its patch on a specific line it expects to find in
`Background.qml` (from the stock `ClockWidget` block). If your fork's
`Background.qml` doesn't match, the script backs out safely and tells you
to add the widget manually — drop this inside the existing
`WidgetCanvas { ... }` block, alongside the other `FadeLoader`s:

```qml
FadeLoader {
    shown: Config.options.background.widgets.revolver.enable
    sourceComponent: RevolverBarrel {
        x: bgRoot.screen.width - width - 80
        y: bgRoot.screen.height - height - 80
        chamberCount: Config.options.background.widgets.revolver.chamberCount
        fireAnimationEnabled: Config.options.background.widgets.revolver.fireAnimation
    }
}
```

`bgRoot` should be the `id` of `Background.qml`'s root `Item`/`Window` (whatever
exposes a `screen` property in your fork) — anchors don't work here since this
runs inside a `Loader.sourceComponent`, which has its own tiny implicit bounds
rather than the screen's.

Also add `import qs` (for the `GlobalStates` singleton the widget's lock-safety
bar and drag-to-spin depend on) and `import qs.modules.revolverBarrel` near the
top of the file.

## Publishing (maintainer notes)

This repo doubles as the AUR source — the `PKGBUILD` at the repo root builds
a `-git` package (`hyprland-revolver-git`) that clones this repo, so there's
nothing extra to keep in sync beyond bumping it after real changes.

### 1. Push this repo to GitHub

```sh
cd hyprland-revolver
git init -b main            # skip if already a repo
git add .
git commit -m "Initial commit"
git remote add origin git@github.com:minerofthesoal/hyprland-revolver.git
git push -u origin main
```

Create the (empty) `hyprland-revolver` repo under your GitHub account first
(web UI, or `gh repo create minerofthesoal/hyprland-revolver --public`) if it
doesn't exist yet.

### 2. Sanity-check the PKGBUILD locally

From a machine with an AUR helper's build tooling (`base-devel`, `git`):

```sh
makepkg -si          # builds + installs, asks for sudo to pacman -U at the end
```

If it builds cleanly, `pkgver()` correctly reports something like
`r1.abcdef0`, and `hyprland-revolver-install` ends up on your `$PATH` and
runs, you're ready to publish.

### 3. Set up AUR access (first time only)

1. Create an account at <https://aur.archlinux.org> if you don't have one.
2. Add an SSH key to your AUR account under **My Account → SSH Public Key**.
3. Point SSH at AUR for that key, e.g. in `~/.ssh/config`:
   ```
   Host aur.archlinux.org
       IdentityFile ~/.ssh/aur
       User aur
   ```

### 4. Publish the AUR package

The AUR repo is separate from the GitHub repo — it only ever holds
`PKGBUILD` and `.SRCINFO`, and pacman/makepkg pull the real source from
GitHub via the `source=()` line at build time.

```sh
git clone ssh://aur@aur.archlinux.org/hyprland-revolver-git.git aur-hyprland-revolver-git
cp PKGBUILD aur-hyprland-revolver-git/
cd aur-hyprland-revolver-git
makepkg --printsrcinfo > .SRCINFO
git add PKGBUILD .SRCINFO
git commit -m "Initial import: hyprland-revolver-git"
git push
```

That first push creates the AUR package (the empty-clone-then-push
pattern is normal — AUR provisions the repo on first push, no separate
"create package" step exists). It'll show up at
`https://aur.archlinux.org/packages/hyprland-revolver-git` shortly after.

### 5. Ship a later update

```sh
# in the GitHub repo
git add -A && git commit -m "..." && git push

# in the AUR repo checkout
cp ../hyprland-revolver/PKGBUILD .   # only if PKGBUILD itself changed
makepkg --printsrcinfo > .SRCINFO
git add -A && git commit -m "Update"
git push
```

Since `pkgver()` derives from `git rev-list`/`git rev-parse` against the
GitHub repo's history, users who reinstall or `-Syu` with an AUR helper pick
up new commits automatically — you don't need to bump anything by hand
unless `pkgrel` needs an unrelated packaging fix.

