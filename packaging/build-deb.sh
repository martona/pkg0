#!/bin/sh
# Build pkg0_<version>_all.deb. Run on a debian-ish box with dpkg-deb.
# usage: packaging/build-deb.sh [version] [self-repo]
set -eu

cd "$(dirname "$0")/.."
VERSION=${1:-0.1.0}
SELF_REPO=${2:-martona/pkg0}

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/DEBIAN" "$STAGE/usr/bin"
install -m 0755 pkg0 "$STAGE/usr/bin/pkg0"
# stamp the script's own version so `pkg0 version` matches the package version
sed -i "s/^PKG0_VERSION=.*/PKG0_VERSION=\"$VERSION\"/" "$STAGE/usr/bin/pkg0"
sed "s/__VERSION__/$VERSION/" packaging/control.in > "$STAGE/DEBIAN/control"
sed "s|__SELF_REPO__|$SELF_REPO|" packaging/postinst > "$STAGE/DEBIAN/postinst"
chmod 0755 "$STAGE/DEBIAN/postinst"

dpkg-deb --root-owner-group --build "$STAGE" "pkg0_${VERSION}_all.deb"
echo "built: pkg0_${VERSION}_all.deb"
