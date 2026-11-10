# syntax=docker/dockerfile:1
#
# A Linux machine to try Yoyo Control on (README.md): Debian 12 (bookworm) with a virtual 1920×1080 desktop (Xvfb +
# Xfce, a terminal, Firefox), PulseAudio, and the yoyo-linux release, started with remote access (`--remote
# /data/remote`) so the iPhone app pairs with it like with a Mac. State (the key, the paired phones) lives in /data:
# mount a volume there. run.sh builds and starts it; the build context is a folder holding this file, entrypoint.sh,
# yoyo and yoyo-linux.tar.gz (the release tar for the image's architecture).
FROM node:22-bookworm-slim

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      xvfb x11-utils xfce4 xfce4-terminal dbus-x11 firefox-esr fonts-noto-cjk fonts-dejavu-core \
      pulseaudio xdotool ffmpeg qrencode ca-certificates \
      libx11-6 libxext6 libxdamage1 libxfixes3 libxi6 libx264-164 libpulse0 libopus0 \
 && apt-get purge -y xfce4-screensaver light-locker xscreensaver 2>/dev/null || true \
 && rm -rf /var/lib/apt/lists/*

COPY yoyo-linux.tar.gz /tmp/
RUN mkdir -p /opt/yoyo-linux && tar -xzf /tmp/yoyo-linux.tar.gz -C /opt/yoyo-linux && rm /tmp/yoyo-linux.tar.gz
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY yoyo /usr/local/bin/yoyo
RUN chmod 755 /usr/local/bin/entrypoint.sh /usr/local/bin/yoyo \
 && useradd -m -s /bin/bash -u 1001 yoyo \
 && mkdir -p /data && chown yoyo:yoyo /data

USER yoyo
WORKDIR /home/yoyo
VOLUME /data
# uu Link (UDP) and its WebRTC socket; publish both on the host, e.g. -p 47830:47820/udp -p 47831:47821/udp
EXPOSE 47820/udp 47821/udp
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
