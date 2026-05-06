# Claude Desktop in a container, accessed via KasmVNC in a web browser.
#
# Claude Desktop is a Windows/macOS Electron app from Anthropic with no official
# Linux build. This image installs the unofficial Linux repackage maintained by
# the claude-desktop-debian community project (Anthropic does not endorse it),
# then exposes the GUI through KasmVNC, which bundles its own Xvnc server +
# web client. Compared to the previous Xvfb -> x11vnc -> noVNC stack, KasmVNC
# does H.264 framebuffer streaming with browser-native video decode (much
# higher FPS, lower CPU on the client), supports audio, clipboard sync, and
# file transfer through a single daemon.
#
# Build:    docker compose build
# Run:      docker compose up -d
# Open:     http://<truenas-host>:8444/   (plain HTTP; put a TLS-terminating
#           reverse proxy in front for any non-LAN exposure)

FROM debian:bookworm-slim

ARG TARGETARCH
# Pin KasmVNC to a known-good release. Bump and rebuild to upgrade.
ARG KASMVNC_VERSION=1.4.0

ENV DEBIAN_FRONTEND=noninteractive \
    DISPLAY=:1 \
    SCREEN_GEOMETRY=1440x900x24 \
    KASMVNC_PORT=8444 \
    HOME=/home/claude \
    USER=claude \
    PUID=1000 \
    PGID=1000 \
    TZ=UTC \
    LANG=C.UTF-8

# Base GUI stack + Electron runtime deps + tooling the apt-repo install needs.
# KasmVNC ships its own Xvnc (X server + VNC + web client), so we no longer
# need xvfb / x11vnc / novnc / websockify.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg sudo tini gosu tzdata \
      git openssh-client \
      openbox xterm \
      dbus-x11 xauth ssl-cert \
      libnss3 libnspr4 libasound2 libgbm1 libgtk-3-0 \
      libdrm2 libxkbcommon0 libxcomposite1 libxdamage1 libxrandr2 \
      libcups2 libpango-1.0-0 libcairo2 libatk1.0-0 libatk-bridge2.0-0 \
      libsecret-1-0 libnotify4 \
      fonts-liberation fonts-dejavu \
      pulseaudio-utils \
      nodejs npm \
    && rm -rf /var/lib/apt/lists/*

# Install KasmVNC from upstream GitHub release. The Bookworm .deb resolves its
# own runtime deps (libxfont2, libpixman-1, openssl, perl, etc.) via apt.
RUN curl -fsSL -o /tmp/kasmvnc.deb \
      "https://github.com/kasmtech/KasmVNC/releases/download/v${KASMVNC_VERSION}/kasmvncserver_bookworm_${KASMVNC_VERSION}_${TARGETARCH}.deb" \
 && apt-get update \
 && apt-get install -y --no-install-recommends /tmp/kasmvnc.deb \
 && rm -f /tmp/kasmvnc.deb \
 && rm -rf /var/lib/apt/lists/*

# Install Claude Desktop from the unofficial community apt repo.
# Repo: https://github.com/aaddrick/claude-desktop-debian
RUN curl -fsSL https://pkg.claude-desktop-debian.dev/KEY.gpg \
      | gpg --dearmor -o /usr/share/keyrings/claude-desktop.gpg \
 && echo "deb [signed-by=/usr/share/keyrings/claude-desktop.gpg arch=amd64,arm64] https://pkg.claude-desktop-debian.dev stable main" \
      > /etc/apt/sources.list.d/claude-desktop.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends claude-desktop \
 && rm -rf /var/lib/apt/lists/*

# Pre-install the Claude Code CLI system-wide. Claude Desktop spawns its own
# bundled copy from ~/.config/Claude/claude-code/<ver>/claude, but having a
# global `claude` available means there's always a working CLI inside the
# container regardless of bind-mount state, and any MCP server / tool that
# expects `claude` on PATH just works.
RUN npm install -g --omit=dev @anthropic-ai/claude-code \
 && npm cache clean --force

# Non-root user. UID/GID get fixed up at runtime in entrypoint.sh so bind-mounts
# from TrueNAS datasets line up with the dataset owner. KasmVNC's vncserver
# wants the user to be in the `ssl-cert` group so it can read the snakeoil
# private key for TLS.
RUN groupadd -g 1000 ${USER} \
 && useradd  -u 1000 -g 1000 -m -s /bin/bash ${USER} \
 && usermod -aG ssl-cert ${USER} \
 && echo "${USER} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USER}

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY openbox-rc.xml /etc/xdg/openbox/rc.xml
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 8444

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
