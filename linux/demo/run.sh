#!/bin/sh
# Builds the test machine's image and (re)starts it as a container, on macOS (Docker Desktop / OrbStack) or Linux:
#
#   linux/demo/run.sh                      # container uu-linux-test, host port 47830 (UDP: uu Link, and the next one for its WebRTC), volume uu-linux-test
#   NAME=box PORT=47831 linux/demo/run.sh  # another one beside it
#   docker exec uu-linux-test yoyo pair    # a pairing link + QR code for the iPhone app (5 min, once)
#
# The release tar: linux/build/yoyo-linux-<version>-linux-<arch>.tar.gz when there (./build.sh), else downloaded from
# the GitHub release linux-v<version> (gh). What the phone is told: this host's LAN IPv4 and its Tailscale IPv4 (if
# any) at PORT. Direct from the internet: the router is asked (UPnP) to forward PORT to this host's LAN address; a
# container can't hear the router's SSDP answers through the NAT, so its UPnP description URL is found here on the host
# (with node, if installed) and passed in — or set UPNP_LOCATION. DIRECT=off / RELAY=off turn those off.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
NAME=${NAME:-uu-linux-test}
PORT=${PORT:-47830}
VERSION=${VERSION:-$(sed -n 's/^export const VERSION = "\(.*\)";$/\1/p' "$here/../server.mjs")}
case "$(docker info -f '{{.Architecture}}')" in
  aarch64 | arm64) arch=arm64 ;;
  x86_64 | amd64) arch=amd64 ;;
  *) echo "run.sh: unsupported architecture" >&2; exit 1 ;;
esac

ctx=$(mktemp -d "${TMPDIR:-/tmp}/uu-linux-demo.XXXXXX")
trap 'rm -rf "$ctx"' EXIT
tar="$here/../build/yoyo-linux-$VERSION-linux-$arch.tar.gz"
if [ -f "$tar" ]; then
  cp "$tar" "$ctx/yoyo-linux.tar.gz"
else
  echo "run.sh: downloading yoyo-linux $VERSION ($arch)"
  gh release download "linux-v$VERSION" -R yoyocontrol/yoyo-control -p "yoyo-linux-$VERSION-linux-$arch.tar.gz" -O "$ctx/yoyo-linux.tar.gz"
fi
cp "$here/Dockerfile" "$here/entrypoint.sh" "$here/yoyo" "$ctx/"

# this host's addresses
if [ "$(uname)" = Darwin ]; then
  lan=$(/usr/sbin/ipconfig getifaddr en0 2>/dev/null || /usr/sbin/ipconfig getifaddr en1 2>/dev/null || true)
  router=$(/sbin/route -n get default 2>/dev/null | awk '/gateway:/ { print $2 }')
  ts=$( (tailscale ip -4 || /Applications/Tailscale.app/Contents/MacOS/Tailscale ip -4) 2>/dev/null | head -1 || true)
else
  lan=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "src") print $(i + 1) }')
  router=$(ip -4 route show default 2>/dev/null | awk '{ print $3; exit }')
  ts=$(tailscale ip -4 2>/dev/null | head -1 || true)
fi
advertise=""
for a in $lan $ts; do advertise="${advertise:+$advertise,}$a:$PORT"; done

# the router's UPnP description URL (an SSDP search from this host)
upnp=${UPNP_LOCATION:-}
if [ -z "$upnp" ] && [ "${DIRECT:-on}" != off ] && [ -n "$router" ] && command -v node >/dev/null 2>&1; then
  upnp=$(node -e '
    const s = require("dgram").createSocket("udp4");
    const msg = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n\r\n";
    s.on("message", (m, r) => { if (r.address !== process.argv[1]) return; const l = /^location:\s*(\S+)/im.exec(m.toString()); if (l) { console.log(l[1]); process.exit(0); } });
    s.bind(0, () => { s.send(msg, 1900, process.argv[1]); s.send(msg, 1900, "239.255.255.250"); });
    setTimeout(() => process.exit(0), 3000);
  ' "$router" 2>/dev/null || true)
fi

echo "run.sh: building $NAME:$VERSION ($arch)"
docker build -q -t "$NAME:$VERSION" "$ctx" >/dev/null
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" --hostname "$NAME" --restart unless-stopped --shm-size 512m \
  -p "$PORT:47820/udp" -p "$((PORT + 1)):47821/udp" -v "$NAME:/data" \
  -e YOYO_NAME="${YOYO_NAME:-Linux test}" \
  -e YOYO_ADVERTISE="$advertise" \
  -e YOYO_DIRECT_CLIENT="${lan:+$lan:$PORT}" \
  -e YOYO_DIRECT_PORT="$PORT" \
  -e YOYO_DIRECT_UPNP="$upnp" \
  -e YOYO_DIRECT="${DIRECT:-on}" \
  -e YOYO_RELAY="${RELAY:-on}" \
  -e YOYO_EXEMPT=gateway \
  "$NAME:$VERSION" >/dev/null
echo "run.sh: $NAME runs (advertising ${advertise:-nothing}; router UPnP ${upnp:-not found})"
echo "run.sh: pair the iPhone app:  docker exec $NAME yoyo pair"
