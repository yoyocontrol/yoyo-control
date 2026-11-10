#!/bin/sh
# Release assets of the Linux server, into build/:
#   yoyo-linux-<version>-linux-<arch>.tar.gz   the .mjs files, vendor/ (with the uu Link addon) + yoyo-x11video,
#                                              yoyo-pa-opus, yoyo-x11clip, yoyo-x11windows
#   SHA256SUMS                                 of the tarballs (`sha256sum -c` format)
# The C helpers are compiled inside Docker (release.Dockerfile) on the supported base, Debian 12 bookworm, one
# --platform per architecture (default arm64 and amd64; the one that isn't this machine's runs emulated: slower, the
# same compiler and libraries). <version> must be server.mjs's VERSION.
#
#   ./build.sh 0.1.0              # both architectures
#   ./build.sh 0.1.0 arm64        # just one
#
# Publishing them (a GitHub release, tag linux-v<version>): README.md「发布」. Needs docker with buildx.
set -eu
cd "$(dirname "$0")"
version="${1:-}"
[ -n "$version" ] || { echo "usage: ./build.sh <version> [arm64] [amd64]" >&2; exit 2; }
shift
archs="${*:-arm64 amd64}"
code="$(sed -n 's/^export const VERSION = "\(.*\)";$/\1/p' server.mjs)"
[ "$code" = "$version" ] || { echo "build.sh: server.mjs's VERSION is $code, not $version" >&2; exit 1; }
# vendor/ must be what the packages build to now (it is committed: the tar carries it as it is)
./vendor.sh --check
# the Rust workspace for the link addon, without its build output (the named context `link-src`)
src=$(mktemp -d "${TMPDIR:-/tmp}/yoyo-link-src.XXXXXX")
trap 'rm -rf "$src"' EXIT
(cd ../link && git ls-files -co --exclude-standard | grep -v '^target/' | while read -r f; do mkdir -p "$src/$(dirname "$f")" && cp "$f" "$src/$f"; done)

out=build
rm -rf "$out"
mkdir -p "$out"
for arch in $archs; do
  case "$arch" in
    arm64 | amd64) ;;
    *) echo "build.sh: unknown architecture $arch (arm64, amd64)" >&2; exit 2 ;;
  esac
  echo "build.sh: linux/$arch"
  docker buildx build --platform "linux/$arch" --build-arg "VERSION=$version" --build-context "link-src=$src" -f release.Dockerfile --output "type=local,dest=$out" .
done
cd "$out"
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum yoyo-linux-*.tar.gz > SHA256SUMS
else
  shasum -a 256 yoyo-linux-*.tar.gz > SHA256SUMS
fi
cat SHA256SUMS
for f in yoyo-linux-*.tar.gz; do
  echo "$f:"
  tar -tvzf "$f"
done
