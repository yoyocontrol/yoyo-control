#!/bin/sh
# The test machine's start: a virtual display (Xvfb), the Xfce desktop on it, PulseAudio (a null sink: what plays is
# what /audio sends), then yoyo-linux with remote access, its state in /data/remote. The rest from the environment:
#
#   YOYO_NAME            the computer's name on the phone (default: Linux test)
#   YOYO_SCREEN          the screen (default 1920x1080x24)
#   YOYO_ADVERTISE       ip[:port],… a phone can reach (the host's LAN / Tailscale address and the published port)
#   YOYO_DIRECT_CLIENT   ip:port the router forwards to (the host's LAN address and the published port)
#   YOYO_DIRECT_UPNP     the router's UPnP description URL (its SSDP answers don't come back through the NAT)
#   YOYO_DIRECT_PORT     the public port to ask the router for
#   YOYO_DIRECT          on | off (default on), YOYO_RELAY on | off (default on)
#   YOYO_EXEMPT          addresses never cooled down; "gateway" = the container's default gateway (every client
#                        reaching a published port arrives from it)
set -eu
export DISPLAY=:0
export XDG_RUNTIME_DIR="/tmp/runtime-$(id -u)"
mkdir -p "$XDG_RUNTIME_DIR" /data/remote
chmod 700 "$XDG_RUNTIME_DIR"
rm -f /tmp/.X0-lock /tmp/.X11-unix/X0

Xvfb :0 -screen 0 "${YOYO_SCREEN:-1920x1080x24}" -nolisten tcp >/tmp/xvfb.log 2>&1 &
i=0
until xdpyinfo >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -lt 100 ] || { echo "entrypoint: Xvfb did not start" >&2; cat /tmp/xvfb.log >&2; exit 1; }
  sleep 0.1
done
pulseaudio --start --exit-idle-time=-1 --disallow-exit >/tmp/pulse.log 2>&1 || echo "entrypoint: no PulseAudio (no sound)" >&2
dbus-launch --exit-with-session startxfce4 >/tmp/xfce.log 2>&1 &

gateway() { awk 'NR > 1 && $2 == "00000000" { h = $3; printf "%d.%d.%d.%d\n", "0x" substr(h, 7, 2), "0x" substr(h, 5, 2), "0x" substr(h, 3, 2), "0x" substr(h, 1, 2); exit }' /proc/net/route; }
exempt="${YOYO_EXEMPT:-}"
case ",$exempt," in *,gateway,*) exempt=$(echo "$exempt" | sed "s/gateway/$(gateway)/") ;; esac

set -- --remote /data/remote --name "${YOYO_NAME:-Linux test}"
[ -n "${YOYO_ADVERTISE:-}" ] && set -- "$@" --advertise "$YOYO_ADVERTISE"
[ -n "${YOYO_DIRECT_CLIENT:-}" ] && set -- "$@" --direct-client "$YOYO_DIRECT_CLIENT"
[ -n "${YOYO_DIRECT_UPNP:-}" ] && set -- "$@" --direct-upnp "$YOYO_DIRECT_UPNP"
[ -n "${YOYO_DIRECT_PORT:-}" ] && set -- "$@" --direct-port "$YOYO_DIRECT_PORT"
[ -n "${YOYO_DIRECT:-}" ] && set -- "$@" --direct "$YOYO_DIRECT"
[ -n "$exempt" ] && set -- "$@" --exempt "$exempt"
exec node /opt/yoyo-linux/server.mjs "$@"
