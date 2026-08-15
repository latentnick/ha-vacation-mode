#!/bin/bash
# Fetch, verify, and cache a pinned Node.js LTS runtime, then extract just the
# `node` binary into a destination directory ($1, as <dest>/bin/node).
#
# Usage: vendor-node.sh <dest-dir>
#   <dest-dir>  Directory to place bin/node into (created if missing).
set -euo pipefail

# Pinned to a hap-nodejs-supported LTS (engines: ^18 || ^20 || ^22 || ^24).
NODE_VERSION="v24.19.0"
SHA_ARM64="8294b7aa9b03997481c06babf1e8b270c859358f27da57a11509afe537ac381d"
SHA_X64="d1b5e999db158c62fe8f7267a4476b035d8bd93b1a605bac24a3f0dd166e3316"

DEST="${1:?usage: vendor-node.sh <dest-dir>}"
CACHE_DIR="${TMPDIR:-/tmp}/lights-node-cache"
mkdir -p "$CACHE_DIR"

case "$(uname -m)" in
  arm64) ARCH="arm64"; SHA="$SHA_ARM64" ;;
  x86_64) ARCH="x64"; SHA="$SHA_X64" ;;
  *) echo "Unsupported arch: $(uname -m)" >&2; exit 1 ;;
esac

TARBALL="node-${NODE_VERSION}-darwin-${ARCH}.tar.gz"
CACHED="$CACHE_DIR/$TARBALL"

verify() {
  echo "$SHA  $1" | shasum -a 256 -c - >/dev/null 2>&1
}

if [[ ! -f "$CACHED" ]] || ! verify "$CACHED"; then
  echo "Downloading ${TARBALL}…"
  curl -fL --retry 3 -o "$CACHED" "https://nodejs.org/dist/${NODE_VERSION}/${TARBALL}"
  verify "$CACHED" || { echo "Checksum mismatch for $TARBALL" >&2; exit 1; }
else
  echo "Using cached $TARBALL"
fi

# Extract just bin/node from the tarball.
EXTRACT_DIR="$CACHE_DIR/node-${NODE_VERSION}-darwin-${ARCH}"
rm -rf "$EXTRACT_DIR"
mkdir -p "$EXTRACT_DIR"
tar -xzf "$CACHED" -C "$EXTRACT_DIR" --strip-components=1 "node-${NODE_VERSION}-darwin-${ARCH}/bin/node"

mkdir -p "$DEST/bin"
cp "$EXTRACT_DIR/bin/node" "$DEST/bin/node"
chmod +x "$DEST/bin/node"
echo "Vendored node ${NODE_VERSION} (${ARCH}) -> $DEST/bin/node"
