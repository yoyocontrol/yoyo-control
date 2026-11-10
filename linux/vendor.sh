#!/bin/sh
# vendor/: the built JS the server imports — committed, so it runs from a checkout or the release tar with nothing
# installed (README.md「远程访问」「uu Link」):
#   vendor/remote   @yoyocontrol/remote (with @yoyocontrol/portmap inside it), which remote.mjs imports
#   vendor/link     @yoyocontrol/link's JS, which link.mjs imports; its native addon (uu-link.linux-<arch>-gnu.node) is
#                   not committed: release.Dockerfile builds it into the tar, a checkout sets YOYO_LINK_NATIVE
# Run it after changing packages/remote, packages/portmap or packages/link (needs `npm install` at the repository root once).
#
#   ./vendor.sh            # rebuild vendor/remote and vendor/link
#   ./vendor.sh --check    # fail when they aren't what the packages build to now (build.sh runs this)
set -eu
cd "$(dirname "$0")"
npm --prefix ../packages/remote run build >/dev/null
npm --prefix ../packages/link run build >/dev/null
tmp=$(mktemp -d "${TMPDIR:-/tmp}/yoyo-vendor.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
for pkg in remote link; do
  mkdir -p "$tmp/$pkg"
  (cd "../packages/$pkg/dist" && find . -name '*.js' | while read -r f; do mkdir -p "$tmp/$pkg/$(dirname "$f")" && cp "$f" "$tmp/$pkg/$f"; done)
done
if [ "${1:-}" = "--check" ]; then
  stale=0
  for pkg in remote link; do
    if ! diff -r -x '*.node' "$tmp/$pkg" "vendor/$pkg" >/dev/null 2>&1; then
      echo "vendor.sh: vendor/$pkg is stale: run ./vendor.sh and commit it" >&2
      diff -r -x '*.node' "$tmp/$pkg" "vendor/$pkg" >&2 || true
      stale=1
    fi
  done
  [ "$stale" = 0 ] || exit 1
  echo "vendor.sh: vendor/remote and vendor/link are current"
  exit 0
fi
mkdir -p vendor
for pkg in remote link; do
  # a native addon put beside vendor/link's JS stays
  find "vendor/$pkg" -name '*.js' -delete 2>/dev/null || true
  mkdir -p "vendor/$pkg"
  cp -R "$tmp/$pkg/." "vendor/$pkg/"
  find "vendor/$pkg" -type d -empty -delete
  echo "vendor.sh: vendor/$pkg ($(find "vendor/$pkg" -name '*.js' | wc -l | tr -d ' ') files)"
done
