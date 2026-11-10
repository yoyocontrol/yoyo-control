#!/usr/bin/env bash
# uu Link for Apple platforms (docs/LINK.md「Swift」): builds the Rust core (link/ffi) as static libraries, packs them
# into YoyoLinkFFI.xcframework and generates the Swift bindings.
#
#   scripts/link-apple.sh build                 # → link/target/apple/YoyoLinkFFI.xcframework (gitignored) and
#                                               #   ios/YoyoKit/Sources/YoyoLink/Generated/YoyoLink.swift (committed)
#   scripts/link-apple.sh check                 # rebuilds the bindings into a temp dir; fails when the committed file
#                                               #   differs (the binary and the Swift must come from the same code)
#   scripts/link-apple.sh release <x.y.z> [<xcframework>]
#                                               # build + check (or take a built one), zip it and print its SwiftPM
#                                               #   checksum: the asset of the public release link-apple-v<x.y.z>,
#                                               #   which the root Package.swift's linkRelease names
#
# Slices: ios-arm64 (aarch64-apple-ios), ios-arm64-simulator (aarch64-apple-ios-sim), macos-arm64
# (aarch64-apple-darwin). Release profile of link/Cargo.toml (fat LTO, panic = abort, stripped).
# cargo needs the network the first time (crates): run outside a sandbox.
#
# With the xcframework built, the root Package.swift has the `YoyoLink` product (it looks for the local build first):
#   scripts/link-apple.sh build && swift build --product YoyoLink
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
link="$root/link"
out="$link/target/apple"
generated="$root/ios/YoyoKit/Sources/YoyoLink/Generated"
targets=(aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin)
lib=libuu_link_ffi.a
export PATH="$HOME/.cargo/bin:$PATH"
# the C parts (ring, blake3) for these OS versions, not the SDK's own (the app's linker warns otherwise). Only the
# C flags: *_DEPLOYMENT_TARGET in the environment also reaches the host's proc macros and breaks the build.
export CFLAGS_aarch64_apple_ios="-miphoneos-version-min=16.0"
export CFLAGS_aarch64_apple_ios_sim="-mios-simulator-version-min=16.0"
export CFLAGS_aarch64_apple_darwin="-mmacosx-version-min=14.0"
# its own target dir: these flags must not churn the artifacts of plain cargo runs
export CARGO_TARGET_DIR="$link/target/apple-cargo"
built="$CARGO_TARGET_DIR"

usage() { sed -n '2,21p' "$0" >&2; exit 2; }

# The Swift sources + header + modulemap of the library in $1, into $2.
# strip_archive <in.a> <out.a>: the archive with the debug info out of Rust's objects and those with DWARF (`strip -S`).
strip_archive() {
  local in="$1" out="$2" tmp
  tmp="$(mktemp -d)"
  local members=()
  while IFS= read -r m; do
    [[ "$m" == __.SYMDEF* ]] || members+=("$m")
  done < <(ar t "$in")
  (cd "$tmp" && ar x "$in")
  for m in "${members[@]}"; do
    if [[ "$m" == *.rcgu.o ]] || otool -l "$tmp/$m" | grep -q "segname __DWARF"; then strip -S "$tmp/$m"; fi
  done
  rm -f "$out"
  (cd "$tmp" && libtool -static -no_warning_for_no_symbols -o "$out" "${members[@]}")
  rm -rf "$tmp"
}

bindings() {
  local library=$1 dir=$2
  rm -rf "$dir" && mkdir -p "$dir"
  (cd "$link" && cargo run --quiet --locked -p uu-link-ffi --features bindgen --bin uniffi-bindgen-swift -- \
    --swift-sources --headers --modulemap \
    --module-name YoyoLinkFFI --modulemap-filename module.modulemap \
    "$library" "$dir")
}

build() {
  for t in "${targets[@]}"; do
    echo "link-apple: building $t"
    (cd "$link" && cargo build --locked --release -p uu-link-ffi --lib --target "$t")
  done
  local gen="$out/bindings"
  bindings "$built/aarch64-apple-darwin/release/$lib" "$gen"

  local headers="$out/headers"
  rm -rf "$headers" && mkdir -p "$headers"
  cp "$gen/YoyoLinkFFI.h" "$gen/module.modulemap" "$headers/"

  # debug info out (~110 MB → ~30 MB per slice), member by member: `strip` over the whole archive also rewrote
  # aws-lc's assembly objects (the rtc transport's DTLS), which the linker then rejected ("address … not in any
  # section"); those have no debug info and are left alone
  rm -rf "$out/YoyoLinkFFI.xcframework" "$out/libs"
  local args=()
  for t in "${targets[@]}"; do
    mkdir -p "$out/libs/$t"
    strip_archive "$built/$t/release/$lib" "$out/libs/$t/$lib"
    args+=(-library "$out/libs/$t/$lib" -headers "$headers")
  done
  xcodebuild -create-xcframework "${args[@]}" -output "$out/YoyoLinkFFI.xcframework" >/dev/null

  mkdir -p "$generated"
  cp "$gen/YoyoLink.swift" "$generated/YoyoLink.swift"
  for t in "${targets[@]}"; do
    printf 'link-apple: %-22s %s\n' "$t" "$(du -h "$out/libs/$t/$lib" | cut -f1)"
  done
  echo "link-apple: $out/YoyoLinkFFI.xcframework, $generated/YoyoLink.swift"
}

check() {
  local tmp
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/link-apple.XXXXXX")
  # once: a RETURN trap stays set and would run again when the caller (publish) returns, $tmp gone by then
  trap 'rm -rf "$tmp"; trap - RETURN' RETURN
  (cd "$link" && cargo build --locked --release -p uu-link-ffi --lib --target aarch64-apple-darwin)
  bindings "$built/aarch64-apple-darwin/release/$lib" "$tmp/gen"
  if ! cmp -s "$tmp/gen/YoyoLink.swift" "$generated/YoyoLink.swift"; then
    echo "link-apple: $generated/YoyoLink.swift is not what the code generates: run scripts/link-apple.sh build and commit it" >&2
    diff -u "$generated/YoyoLink.swift" "$tmp/gen/YoyoLink.swift" | head -40 >&2 || true
    return 1
  fi
  echo "link-apple: generated bindings match"
}

release() {
  local version=$1 from=${2:-}
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version is x.y.z" >&2; exit 2; }
  if [ -z "$from" ]; then
    if [ -n "$(git -C "$root" status --porcelain -- link ios/YoyoKit/Sources/YoyoLink scripts/link-apple.sh)" ]; then
      echo "link/ or the bindings have uncommitted changes: commit them first (the release names its source)" >&2
      exit 1
    fi
    build
    check
    from="$out/YoyoLinkFFI.xcframework"
  fi
  [ -f "$from/Info.plist" ] || { echo "$from is not an xcframework" >&2; exit 1; }
  local zip="$out/YoyoLinkFFI-$version.xcframework.zip"
  mkdir -p "$out"
  rm -f "$zip"
  (cd "$(dirname "$from")" && ditto -c -k --sequesterRsrc --keepParent "$(basename "$from")" "$zip")
  local sum
  sum=$(swift package compute-checksum "$zip")
  echo "link-apple: $zip"
  echo "  upload it as the asset of the release link-apple-v$version (gh release create link-apple-v$version $zip …), then set"
  echo "  Package.swift's linkRelease to:"
  echo "    (url: \"https://github.com/yoyocontrol/yoyo-control/releases/download/link-apple-v$version/$(basename "$zip")\","
  echo "     checksum: \"$sum\")"
}

case "${1:-}" in
  build) build ;;
  check) check ;;
  release) [ $# -ge 2 ] || usage; release "$2" "${3:-}" ;;
  *) usage ;;
esac
