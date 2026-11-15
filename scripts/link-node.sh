#!/usr/bin/env bash
# uu Link for Node (packages/link, docs/LINK.md「Node」) as release assets: one archive per system, for programs that
# download the library instead of building it (nest's gateway, docs/LINK.md「发布」).
#
#   scripts/link-node.sh release <x.y.z>   # → link/target/link-node/<x.y.z>/uu-link-node-<x.y.z>-<os>-<arch>.tgz
#                                          #   + SHA256SUMS: the assets of the public release link-node-v<x.y.z>
#
# Each archive: package.json (version <x.y.z>), dist/ (the JavaScript), native/uu-link.<os>-<arch>[-gnu].node (the one
# addon of that system), LICENSE, NOTICE. The package's loader finds native/ beside dist/ (src/native.ts).
# Systems: darwin-arm64 (this Mac), linux-x64 and linux-arm64 (linux/release.Dockerfile's link-addon stage, docker
# buildx), win32-x64 (mingw-w64, as windows/build.sh builds the screen server's). Profile release-node.
# cargo and docker need the network the first time: run outside a sandbox.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
link="$root/link"
pkg="$root/packages/link"
export PATH="$HOME/.cargo/bin:$PATH"

usage() { sed -n '2,14p' "$0" >&2; exit 2; }
[[ ${1:-} == release && ${2:-} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || usage
version=$2
out="$link/target/link-node/$version"
work="$out/work"
rm -rf "$out" && mkdir -p "$work/addons"

say() { echo "link-node: $*" >&2; }

# ---- the JavaScript (the same for every system)
say "building dist/ ..."
(cd "$pkg" && npm run -s build)

# ---- darwin-arm64: this Mac
[[ $(uname -s) == Darwin && $(uname -m) == arm64 ]] || { say "the darwin-arm64 addon is built on an Apple silicon Mac"; exit 1; }
say "darwin-arm64 ..."
(cd "$link" && cargo build -q --locked --profile release-node -p uu-link-node)
cp "$link/target/release-node/libuu_link_node.dylib" "$work/addons/uu-link.darwin-arm64.node"

# ---- linux-x64, linux-arm64: the release image's Rust stage
for arch in amd64 arm64; do
  name=$([[ $arch == amd64 ]] && echo x64 || echo arm64)
  say "linux-$name (docker buildx, linux/$arch) ..."
  docker buildx build -q --platform "linux/$arch" --build-context "link-src=$link" -f "$root/linux/release.Dockerfile" \
    --target link-addon --output "type=local,dest=$work/linux-$arch" "$root/linux" >/dev/null
  cp "$work/linux-$arch/uu-link.node" "$work/addons/uu-link.linux-$name-gnu.node"
done

# ---- win32-x64: mingw-w64. The addon imports N-API from node.exe: an import library made from napi-sys's names
say "win32-x64 (mingw-w64) ..."
host=x86_64-w64-mingw32
# (a fixed place, not under the version's work directory: the addon's build script records this path, and cargo reuses
# that record on the next release, after the work directory is gone)
libnode="$link/target/link-node/libnode"
mkdir -p "$libnode" && : > "$libnode/libnode.dll"
napi_sys=$(cd "$link" && cargo metadata --format-version 1 2>/dev/null | python3 -c 'import json,sys; print([p["manifest_path"] for p in json.load(sys.stdin)["packages"] if p["name"]=="napi-sys"][0])')
{ echo "LIBRARY node.exe"; echo "EXPORTS"; grep -rhoE '\b(napi|node_api|uv)_[a-z0-9_]+\b' "$(dirname "$napi_sys")/src" | sort -u | sed 's/^/  /'; } > "$libnode/node.def"
$host-dlltool -d "$libnode/node.def" -l "$libnode/libnode.a" -D node.exe
(cd "$link" && LIBNODE_PATH="$libnode" CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER=$host-gcc CC_x86_64_pc_windows_gnu=$host-gcc \
  CXX_x86_64_pc_windows_gnu=$host-g++ AR_x86_64_pc_windows_gnu=$host-ar \
  cargo build -q --locked --profile release-node -p uu-link-node --target x86_64-pc-windows-gnu)
cp "$link/target/x86_64-pc-windows-gnu/release-node/uu_link_node.dll" "$work/addons/uu-link.win32-x64.node"

# ---- one archive per system: same bytes from the same sources (fixed owner, modes and times, sorted, no gzip time)
for addon in "$work"/addons/*.node; do
  sys=$(basename "$addon" .node); sys=${sys#uu-link.}; sys=${sys%-gnu}
  stage="$work/stage-$sys"
  mkdir -p "$stage/native"
  cp -R "$pkg/dist" "$stage/dist"
  cp "$addon" "$stage/native/"
  node -e 'const fs=require("fs");const [src,dst,v]=process.argv.slice(1);const p=JSON.parse(fs.readFileSync(src,"utf8"));p.version=v;delete p.scripts;delete p.devDependencies;fs.writeFileSync(dst,JSON.stringify(p,null,2)+"\n")' "$pkg/package.json" "$stage/package.json" "$version"
  cp "$root/LICENSE" "$root/NOTICE" "$stage/" 2>/dev/null || cp "$root/LICENSE" "$stage/"
  find "$stage" -type d -exec chmod 755 {} + && find "$stage" -type f -exec chmod 644 {} +
  (cd "$stage" && find . -type f | LC_ALL=C sort | sed 's|^\./||' > "$work/files-$sys" \
    && COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata --uid 0 --gid 0 --uname root --gname root -cf - -T "$work/files-$sys" | gzip -9n > "$out/uu-link-node-$version-$sys.tgz")
done
(cd "$out" && shasum -a 256 uu-link-node-*.tgz > SHA256SUMS && cat SHA256SUMS)
rm -rf "$work"
