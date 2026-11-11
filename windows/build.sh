#!/bin/zsh
# The Windows release (windows/README.md「发布」): build/yoyo-windows-<version>-windows-x64.zip + build/SHA256SUMS.
# Cross-compiled on a Mac or Linux box with mingw-w64 (brew install mingw-w64 / apt install mingw-w64), nasm, cmake and
# Rust (rustup target add x86_64-pc-windows-gnu). Pinned and checked: x264 (a commit), libopus (a release tarball),
# node.exe (the official win-x64 zip, against nodejs.org's SHASUMS256). The version is linux/server.mjs's VERSION
# (the same server): ./build.sh stops when they differ.
#
#   cd windows && ./build.sh 0.9.0
set -euo pipefail
VERSION=${1:?usage: ./build.sh <version>}
HERE=${0:A:h}
ROOT=${HERE:h}
SRV_VERSION=$(sed -n 's/^export const VERSION = "\(.*\)";/\1/p' $ROOT/linux/server.mjs)
[[ $VERSION == $SRV_VERSION ]] || { echo "linux/server.mjs says $SRV_VERSION, not $VERSION" >&2; exit 1; }

X264_COMMIT=0480cb05fa188d37ae87e8f4fd8f1aea3711f7ee
OPUS_VERSION=1.5.2
OPUS_SHA256=65c1d2f78b9f2fb20082c38cbe47c951ad5839345876e46941612ee87f9a7ce1
NODE_VERSION=24.22.2
NODE_SHA256=ca1bff5d8ead13c9f2ea404a176db46bd430704d5b5113734049fa365e7799e2
HOST=x86_64-w64-mingw32
CC=$HOST-gcc

B=$HERE/build
DEPS=$B/deps
OUT=$B/stage
mkdir -p $DEPS/src
rm -rf $OUT && mkdir -p $OUT/vendor

# ---- x264, libopus: static, into $DEPS
if [[ ! -f $DEPS/lib/libx264.a ]]; then
  rm -rf $DEPS/src/x264
  git clone -q https://code.videolan.org/videolan/x264.git $DEPS/src/x264
  git -C $DEPS/src/x264 checkout -q $X264_COMMIT
  (cd $DEPS/src/x264 && ./configure --host=$HOST --cross-prefix=$HOST- --prefix=$DEPS --enable-static --disable-cli --enable-strip --bit-depth=8 --chroma-format=420 >/dev/null && make -j8 >/dev/null && make install >/dev/null)
fi
if [[ ! -f $DEPS/lib/libopus.a ]]; then
  curl -fsSL -o $DEPS/src/opus.tgz https://downloads.xiph.org/releases/opus/opus-$OPUS_VERSION.tar.gz
  echo "$OPUS_SHA256  $DEPS/src/opus.tgz" | shasum -a 256 -c - >/dev/null
  rm -rf $DEPS/src/opus && mkdir $DEPS/src/opus && tar -xzf $DEPS/src/opus.tgz -C $DEPS/src/opus --strip-components 1
  cmake -S $DEPS/src/opus -B $DEPS/src/opus/build -DCMAKE_SYSTEM_NAME=Windows -DCMAKE_C_COMPILER=$CC -DCMAKE_INSTALL_PREFIX=$DEPS \
    -DCMAKE_BUILD_TYPE=Release -DOPUS_BUILD_SHARED_LIBRARY=OFF -DOPUS_BUILD_TESTING=OFF -DOPUS_BUILD_PROGRAMS=OFF >/dev/null
  cmake --build $DEPS/src/opus/build -j8 >/dev/null && cmake --install $DEPS/src/opus/build >/dev/null
fi

# ---- the helpers and the launcher (static: no DLLs beside them)
F=(-O2 -Wall -Wextra -Wno-unused-function -Wno-unused-parameter -Wno-missing-field-initializers -static -s -I$DEPS/include -L$DEPS/lib)
cd $HERE
# winvideo.c includes winhw.h (the GPU encoder: Media Foundation is loaded at run time, only its GUIDs are linked)
$CC $F -Wno-missing-braces -o $OUT/yoyo-winvideo.exe winvideo.c -lx264 -ld3d11 -ldxgi -lole32 -loleaut32 -lwindowscodecs -lmfuuid -lstrmiids -ldxguid -luuid -lwinmm -lgdi32
$CC $F -o $OUT/yoyo-winaudio.exe winaudio.c -lopus -lole32 -lwinmm -luuid -lksuser
$CC $F -o $OUT/yoyo-winclip.exe winclip.c -lole32 -loleaut32 -lwindowscodecs -luuid -lshell32
$CC $F -o $OUT/yoyo-winwindows.exe winwindows.c -ldwmapi
$CC $F -o $OUT/yoyo-wininput.exe wininput.c
$HOST-windres launcher.rc -O coff -o $B/launcher.res
$CC $F -municode -mwindows -o $OUT/yoyo-control.exe launcher.c $B/launcher.res -lshell32 -lole32 -luuid

# ---- uu Link's addon: napi-rs for x86_64-pc-windows-gnu. It imports N-API from node.exe: an import library made from
# napi-sys's names (napi-build wants a libnode.dll to exist; nothing of it is used)
LIBNODE=$B/libnode
mkdir -p $LIBNODE && : > $LIBNODE/libnode.dll
NAPI_SYS=$(cd $ROOT/link && cargo metadata --format-version 1 2>/dev/null | python3 -c 'import json,sys; print([p["manifest_path"] for p in json.load(sys.stdin)["packages"] if p["name"]=="napi-sys"][0])')
{ echo "LIBRARY node.exe"; echo "EXPORTS"; grep -rhoE '\b(napi|node_api|uv)_[a-z0-9_]+\b' ${NAPI_SYS:h}/src | sort -u | sed 's/^/  /'; } > $LIBNODE/node.def
$HOST-dlltool -d $LIBNODE/node.def -l $LIBNODE/libnode.a -D node.exe
(cd $ROOT/link && LIBNODE_PATH=$LIBNODE CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER=$CC CC_x86_64_pc_windows_gnu=$CC \
  CXX_x86_64_pc_windows_gnu=$HOST-g++ AR_x86_64_pc_windows_gnu=$HOST-ar cargo build -q --release -p uu-link-node --target x86_64-pc-windows-gnu)

# ---- node.exe
NODE_ZIP=$DEPS/src/node-v$NODE_VERSION-win-x64.zip
[[ -f $NODE_ZIP ]] || curl -fsSL -o $NODE_ZIP https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION-win-x64.zip
echo "$NODE_SHA256  $NODE_ZIP" | shasum -a 256 -c - >/dev/null
unzip -q -o -j $NODE_ZIP "node-v$NODE_VERSION-win-x64/node.exe" "node-v$NODE_VERSION-win-x64/LICENSE" -d $B/node
cp $B/node/node.exe $OUT/node.exe

# ---- the server (the same .mjs as Linux), its vendored packages, the scripts
(cd $ROOT/linux && ./vendor.sh --check)
cp $ROOT/linux/*.mjs $OUT/
cp -R $ROOT/linux/vendor/remote $ROOT/linux/vendor/link $OUT/vendor/
rm -f $OUT/vendor/link/*.node(N)
cp $ROOT/link/target/x86_64-pc-windows-gnu/release/uu_link_node.dll $OUT/vendor/link/uu-link.win32-x64.node
cp install.ps1 uninstall.ps1 yoyo.cmd $OUT/
# cmd.exe wants CRLF
perl -pi -e "s/\\r?\\n/\\r\\n/" $OUT/yoyo.cmd
mkdir -p $OUT/licenses
cp $B/node/LICENSE $OUT/licenses/node.txt
cp $DEPS/src/x264/COPYING $OUT/licenses/x264.txt
cp $DEPS/src/opus/COPYING $OUT/licenses/opus.txt
cat > $OUT/licenses/README.txt <<EOF
yoyo-winvideo.exe links x264 (GPL-2.0-or-later) statically: source https://code.videolan.org/videolan/x264, commit $X264_COMMIT.
yoyo-winaudio.exe links libopus $OPUS_VERSION (BSD-3-Clause): https://opus-codec.org.
node.exe is Node.js $NODE_VERSION (MIT; its LICENSE lists what it bundles): https://nodejs.org.
EOF
# PowerShell 5 reads a script without a BOM in the ANSI code page: the scripts get one
for f in $OUT/install.ps1 $OUT/uninstall.ps1; do printf '\xef\xbb\xbf' | cat - $f > $f.tmp && mv $f.tmp $f; done

# ---- the zip: sorted, fixed times (the same sources make the same bytes, as far as zip allows)
ZIP=$B/yoyo-windows-$VERSION-windows-x64.zip
rm -f $ZIP
find $OUT -exec touch -h -t 202601010000 {} +
(cd $OUT && find . -type f | LC_ALL=C sort | sed 's|^\./||' | TZ=UTC zip -q -X -D $ZIP -@)
(cd $B && shasum -a 256 ${ZIP:t} > SHA256SUMS)
echo "built $ZIP"
cat $B/SHA256SUMS
