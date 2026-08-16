#!/usr/bin/env bash
# Publishes (or updates) the hyprland-revolver-git AUR package from the
# PKGBUILD in this repo. Run this yourself, locally, on an Arch machine
# with base-devel installed and your AUR SSH key already configured
# (~/.ssh/config Host aur.archlinux.org ...) - it needs your AUR identity
# to push, which is exactly why it can't run anywhere but your own machine.
#
# Safe to re-run: does nothing if PKGBUILD/.SRCINFO haven't changed since
# the last push.
set -euo pipefail

PKGNAME="hyprland-revolver-git"
AUR_SSH="ssh://aur@aur.archlinux.org/${PKGNAME}.git"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

echo "== Publishing $PKGNAME to the AUR =="

command -v makepkg >/dev/null 2>&1 || {
    echo "!! makepkg not found - this needs to run on an Arch machine with base-devel installed"
    exit 1
}
command -v git >/dev/null 2>&1 || { echo "!! git not found"; exit 1; }
[ -f "$REPO_ROOT/PKGBUILD" ] || { echo "!! No PKGBUILD next to this script"; exit 1; }
[ -f "$REPO_ROOT/hyprland-revolver-git.install" ] || { echo "!! No hyprland-revolver-git.install next to this script"; exit 1; }

echo "-> cloning $AUR_SSH"
echo "   (if this is the first-ever publish, an empty repo is expected here -"
echo "    AUR provisions the real package on the first push, not on clone)"
git clone "$AUR_SSH" "$WORKDIR/$PKGNAME"
cd "$WORKDIR/$PKGNAME"

cp "$REPO_ROOT/PKGBUILD" .
cp "$REPO_ROOT/hyprland-revolver-git.install" .

echo "-> generating .SRCINFO"
makepkg --printsrcinfo > .SRCINFO

git add PKGBUILD hyprland-revolver-git.install .SRCINFO
if git diff --cached --quiet; then
    echo "-> PKGBUILD/.install/.SRCINFO unchanged since the last publish, nothing to push"
    exit 0
fi

git commit -m "Update PKGBUILD ($(date +%Y-%m-%d))"
git push origin HEAD:master

echo
echo "-> pushed. Live at: https://aur.archlinux.org/packages/${PKGNAME}"
