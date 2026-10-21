#!/usr/bin/env bash
# Release packages of the game into build/release/:
#   noheroneeds-V-linux-x86_64.tar.gz     the Linux binary (and its SQLite library)
#   noheroneeds-V-windows-portable.zip    the Windows .exe to run from anywhere
#   noheroneeds-V-windows-setup.exe       the Windows installer (Start menu, desktop, uninstall)
#   noheroneeds_V_amd64.deb               for Debian and Ubuntu (menu entry, icons)
# Usage: tools/package.sh [VERSION]   (a tag such as v0.2.0 or 0.2.0; default: content/base/pack.json's)
# Env: GODOT (binary, default "godot") with its export templates; makensis
# for the installer (skipped with a note when missing); dpkg-deb, fakeroot.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-$(python3 -c "import json;print(json.load(open('$ROOT/content/base/pack.json'))['version'])")}"
VERSION="${VERSION#v}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must be X.Y.Z, got '$VERSION'" >&2; exit 1; }
OUT="$ROOT/build/release"
PKG="$ROOT/tools/packaging"
WORK="$(mktemp -d)"
# The version goes into the game (Windows file info, the menu's About) for this build only.
cp "$ROOT/project.godot" "$WORK/project.godot.kept"
trap 'cp "$WORK/project.godot.kept" "$ROOT/project.godot"; rm -rf "$WORK"' EXIT
sed -i "s/^config\/version=.*/config\/version=\"$VERSION\"/" "$ROOT/project.godot"

"$ROOT/tools/export.sh" all
rm -rf "$OUT"
mkdir -p "$OUT"
LIN="$ROOT/build/linux"
WIN="$ROOT/build/windows"

# Linux: the binary, its library, the icon and the art's authors.
D="$WORK/noheroneeds-$VERSION"
mkdir -p "$D"
cp "$LIN"/* "$D"/
cp "$ROOT/assets/icon/icon-256.png" "$D/noheroneeds.png"
cp "$ROOT/CREDITS-art.md" "$D"/
tar -C "$WORK" -czf "$OUT/noheroneeds-$VERSION-linux-x86_64.tar.gz" "noheroneeds-$VERSION"
rm -rf "$D"

# Windows, portable: unpack anywhere and run.
D="$WORK/noheroneeds-$VERSION-windows"
mkdir -p "$D"
cp "$WIN"/* "$D"/
cp "$ROOT/CREDITS-art.md" "$D"/
(cd "$WORK" && zip -qr "$OUT/noheroneeds-$VERSION-windows-portable.zip" "noheroneeds-$VERSION-windows")

# Windows, installer (NSIS builds it on Linux too).
if command -v makensis >/dev/null; then
  makensis -V2 -DVERSION="$VERSION" -DSRC="$D" -DICON="$ROOT/assets/icon/icon.ico" \
    -DOUT="$OUT/noheroneeds-$VERSION-windows-setup.exe" "$PKG/windows/installer.nsi"
else
  echo "makensis not found: no Windows installer (apt install nsis)" >&2
fi
rm -rf "$D"

# Debian / Ubuntu: under /opt, started from /usr/games, in the menu with its icons.
D="$WORK/deb"
mkdir -p "$D/DEBIAN" "$D/opt/noheroneeds" "$D/usr/games" "$D/usr/share/applications" \
  "$D/usr/share/metainfo" "$D/usr/share/doc/noheroneeds"
cp "$LIN"/* "$D/opt/noheroneeds/"
chmod 755 "$D/opt/noheroneeds/noheroneeds.x86_64"
chmod 644 "$D"/opt/noheroneeds/*.so
install -m 755 "$PKG/linux/noheroneeds" "$D/usr/games/noheroneeds"
install -m 644 "$PKG/linux/noheroneeds.desktop" "$D/usr/share/applications/noheroneeds.desktop"
install -m 644 "$PKG/linux/io.github.mirivlad.noheroneeds.metainfo.xml" "$D/usr/share/metainfo/"
for s in 16 24 32 48 64 128 256 512; do
  install -D -m 644 "$ROOT/assets/icon/icon-$s.png" "$D/usr/share/icons/hicolor/${s}x${s}/apps/noheroneeds.png"
done
install -m 644 "$ROOT/CREDITS-art.md" "$D/usr/share/doc/noheroneeds/CREDITS-art.md"
cat > "$D/usr/share/doc/noheroneeds/copyright" <<COPY
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: No Hero Needed
Source: https://github.com/mirivlad/noheroneeds

Files: *
Copyright: No Hero Needed contributors
License: see the project's repository

Files: opt/noheroneeds/*.so
Copyright: 2shady4u and contributors (godot-sqlite)
License: MIT

Comment: The game's pictures and sounds come from the Liberated Pixel Cup and
 other free sets (CC-BY-SA 3.0, CC-BY, OGA-BY, GPL, CC0); their authors and
 licences are listed in /usr/share/doc/noheroneeds/CREDITS-art.md.
COPY
chmod -R u=rwX,go=rX "$D"  # directories 755, files 644, programs kept runnable
SIZE="$(du -sk "$D" --exclude=DEBIAN | cut -f1)"
cat > "$D/DEBIAN/control" <<CONTROL
Package: noheroneeds
Version: $VERSION
Section: games
Priority: optional
Architecture: amd64
Installed-Size: $SIZE
Maintainer: mirivlad <mirvtop@yandex.ru>
Depends: libc6 (>= 2.31), libgl1, libx11-6
Recommends: libasound2 | libasound2t64, libpulse0, libxcursor1, libxinerama1, libxrandr2, libxi6, libxext6, libfontconfig1
Homepage: https://github.com/mirivlad/noheroneeds
Description: long-lived 2D pixel sandbox game
 Build a home, plough fields, hunt and fish, trade with villages joined by
 roads and go down into caves, through biomes, seasons and weather; alone or
 together on a server.
CONTROL
fakeroot dpkg-deb --build --root-owner-group -Zxz "$D" "$OUT/noheroneeds_${VERSION}_amd64.deb" >/dev/null

(cd "$OUT" && sha256sum -- * > SHA256SUMS)
ls -la "$OUT"
