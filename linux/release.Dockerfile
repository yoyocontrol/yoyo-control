# syntax=docker/dockerfile:1
#
# The release tarball of one architecture (build.sh runs this once per --platform; context: linux/, plus the named
# context `link-src` = the Rust workspace link/ without target/): the four C helpers compiled on the supported base, the uu
# Link addon (cross-compiled on the build machine for the target's glibc), then packed flat with the .mjs files and
# vendor/ (the built JS of @yoyocontrol/remote and @yoyocontrol/link, for --remote; the addon beside vendor/link's JS)
# — extract into one folder and run `node server.mjs` there: nothing to install. The helpers link libX11 / libXext / libXdamage / libXfixes / libXi / libx264 / libpulse / libopus
# dynamically: they run on that same Debian release with its runtime packages (README.md「要求」).
ARG BASE=debian:bookworm-slim

# uu Link's Node addon (link/node): built natively on the build machine, cross to the target (gcc's cross linker; the
# only C in it is ring), against bookworm's glibc like the helpers
FROM --platform=$BUILDPLATFORM rust:1.96-slim-bookworm AS link-addon
ARG TARGETARCH
# (Debian's package is gcc-x86-64-linux-gnu, its compiler x86_64-linux-gnu-gcc)
RUN case "$TARGETARCH" in amd64) t=x86_64-unknown-linux-gnu g=x86_64-linux-gnu ;; arm64) t=aarch64-unknown-linux-gnu g=aarch64-linux-gnu ;; *) exit 1 ;; esac \
 && apt-get update && apt-get install -y --no-install-recommends gcc-$(echo $g | tr _ -) libc6-dev-$TARGETARCH-cross && rm -rf /var/lib/apt/lists/* \
 && rustup target add $t && echo "$t $g" > /target
COPY --from=link-src . /link
WORKDIR /link
# the image's toolchain, with the target added above (rust-toolchain.toml names the same release with the Apple targets)
RUN rm -f rust-toolchain.toml && read t g < /target \
 && T=$(echo $t | tr 'a-z-' 'A-Z_') \
 && env "CARGO_TARGET_${T}_LINKER=$g-gcc" "CC_$(echo $t | tr - _)=$g-gcc" \
      cargo build --locked --profile release-node -p uu-link-node --target $t \
 && cp target/$t/release-node/libuu_link_node.so /uu-link.node \
 && $g-strip /uu-link.node

FROM ${BASE} AS build
RUN apt-get update \
 && apt-get install -y --no-install-recommends gcc libc6-dev libx11-dev libxext-dev libxdamage-dev libxfixes-dev libxi-dev libx264-dev \
      libpulse-dev libopus-dev binutils \
 && rm -rf /var/lib/apt/lists/*
COPY x11video.c x264enc.h videoio.h pa-opus.c x11clip.c x11windows.c /src/
RUN mkdir /pkg \
 && gcc -O2 -Wall -Wextra -Werror -o /pkg/yoyo-x11video /src/x11video.c -lX11 -lXext -lXdamage -lXfixes -lx264 \
 && gcc -O2 -Wall -Wextra -Werror -o /pkg/yoyo-pa-opus /src/pa-opus.c -lpulse-simple -lpulse -lopus -lm -lpthread \
 && gcc -O2 -Wall -Wextra -Werror -o /pkg/yoyo-x11clip /src/x11clip.c -lX11 -lXfixes \
 && gcc -O2 -Wall -Wextra -Werror -o /pkg/yoyo-x11windows /src/x11windows.c -lX11 -lXi \
 && strip /pkg/yoyo-*
COPY *.mjs /pkg/
COPY vendor /pkg/vendor
ARG VERSION
ARG TARGETARCH
COPY --from=link-addon /uu-link.node /tmp/uu-link.node
RUN rm -f /pkg/vendor/link/*.node \
 && cp /tmp/uu-link.node "/pkg/vendor/link/uu-link.linux-$(case "$TARGETARCH" in amd64) echo x64 ;; *) echo "$TARGETARCH" ;; esac)-gnu.node"
# root-owned, fixed modes and times, sorted, no gzip timestamp: the same sources give the same bytes
RUN test -n "$VERSION" && test -n "$TARGETARCH" \
 && chmod 755 /pkg/yoyo-* && chmod 644 /pkg/*.mjs \
 && find /pkg/vendor -type d -exec chmod 755 {} + && find /pkg/vendor -type f -exec chmod 644 {} + \
 && cd /pkg \
 && tar --sort=name --owner=0 --group=0 --numeric-owner --mtime=@0 -cf - * | gzip -9n > "/yoyo-linux-$VERSION-linux-$TARGETARCH.tar.gz"

FROM scratch
COPY --from=build /yoyo-linux-*.tar.gz /
