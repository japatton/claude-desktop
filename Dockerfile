# Claude Desktop in a container, accessed via noVNC in a web browser.
#
# Claude Desktop is a Windows/macOS Electron app from Anthropic with no official
# Linux build. This image installs the unofficial Linux repackage maintained by
# the claude-desktop-debian community project (Anthropic does not endorse it),
# then exposes the GUI through Xvfb -> x11vnc -> noVNC.
#
# Build:    docker compose build
# Run:      docker compose up -d
# Open:     http://<truenas-host>:6080/vnc.html

FROM debian:bookworm-slim

ARG TARGETARCH

ENV DEBIAN_FRONTEND=noninteractive \
    DISPLAY=:1 \
    SCREEN_GEOMETRY=1440x900x24 \
    VNC_PORT=5901 \
    NOVNC_PORT=6080 \
    HOME=/home/claude \
    USER=claude \
    PUID=1000 \
    PGID=1000 \
    TZ=UTC \
    LANG=C.UTF-8

# GUI stack + Electron runtime deps + tooling the apt-repo install needs.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg sudo tini gosu tzdata \
      xvfb x11vnc novnc websockify \
      openbox xterm \
      dbus-x11 \
      libnss3 libnspr4 libasound2 libgbm1 libgtk-3-0 \
      libdrm2 libxkbcommon0 libxcomposite1 libxdamage1 libxrandr2 \
      libcups2 libpango-1.0-0 libcairo2 libatk1.0-0 libatk-bridge2.0-0 \
      libsecret-1-0 libnotify4 \
      fonts-liberation fonts-dejavu \
      pulseaudio-utils \
      nodejs npm \
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
# from TrueNAS datasets line up with the dataset owner.
RUN groupadd -g 1000 ${USER} \
 && useradd  -u 1000 -g 1000 -m -s /bin/bash ${USER} \
 && echo "${USER} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USER}

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY openbox-rc.xml /etc/xdg/openbox/rc.xml
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 6080 5901

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
