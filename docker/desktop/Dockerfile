# A throwaway Linux desktop for the desktop-container display target: an X server on :99 with a window manager,
# the driver's tools (xdotool, ImageMagick's import, xprop), and a few apps. Build it with:
#   docker build -t swiftagentharness/desktop:latest docker/desktop
FROM debian:bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      xvfb fluxbox xdotool imagemagick x11-utils procps \
      xterm mousepad xdg-utils fonts-dejavu-core dbus-x11 \
 && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --shell /bin/bash desktop
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 755 /usr/local/bin/entrypoint.sh

USER desktop
WORKDIR /home/desktop
ENV DISPLAY=:99 SCREEN=1280x800x24
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
