#!/usr/bin/env bash
set -euo pipefail

: "${DISPLAY:=:1}"
: "${SCREEN_GEOMETRY:=1440x900x24}"
: "${VNC_PORT:=5901}"
: "${NOVNC_PORT:=6080}"
: "${USER:=claude}"
: "${HOME:=/home/claude}"
: "${PUID:=1000}"
: "${PGID:=1000}"
: "${TZ:=UTC}"
: "${VNC_PASSWORD:=}"

# --- Timezone ---
if [ -f "/usr/share/zoneinfo/${TZ}" ]; then
  ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime
  echo "${TZ}" > /etc/timezone
fi

# --- Align user UID/GID with TrueNAS dataset owner ---
if [ "$(id -u "${USER}")" != "${PUID}" ] || [ "$(id -g "${USER}")" != "${PGID}" ]; then
  groupmod -o -g "${PGID}" "${USER}"
  usermod  -o -u "${PUID}" -g "${PGID}" "${USER}"
  chown -R "${PUID}:${PGID}" "${HOME}"
fi

mkdir -p "${HOME}/.config/Claude"
chown -R "${PUID}:${PGID}" "${HOME}/.config"

# --- Clean stale X locks (image restart leaves these behind) ---
rm -f /tmp/.X1-lock /tmp/.X11-unix/X1 || true
mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix

# --- VNC password (optional) ---
VNC_AUTH_ARGS=(-nopw)
if [ -n "${VNC_PASSWORD}" ]; then
  mkdir -p "${HOME}/.vnc"
  x11vnc -storepasswd "${VNC_PASSWORD}" "${HOME}/.vnc/passwd" >/dev/null
  chown -R "${PUID}:${PGID}" "${HOME}/.vnc"
  VNC_AUTH_ARGS=(-rfbauth "${HOME}/.vnc/passwd")
fi

# --- Background services ---
# Xvfb: virtual X display
Xvfb "${DISPLAY}" -screen 0 "${SCREEN_GEOMETRY}" -ac +extension GLX +render -noreset &

# Wait for X to come up
for _ in $(seq 1 30); do
  if [ -S /tmp/.X11-unix/X1 ]; then break; fi
  sleep 0.1
done

# D-Bus session bus (Electron / GTK want this)
eval "$(dbus-launch --sh-syntax)"
export DBUS_SESSION_BUS_ADDRESS DBUS_SESSION_BUS_PID

# Window manager (provides decorations, focus, alt-tab)
gosu "${USER}" openbox --config-file /etc/xdg/openbox/rc.xml &

# VNC server bound to the Xvfb display
x11vnc -display "${DISPLAY}" -forever -shared -rfbport "${VNC_PORT}" \
       "${VNC_AUTH_ARGS[@]}" -quiet -bg

# noVNC web client (websockify bridges browser <-> VNC)
websockify --web=/usr/share/novnc "${NOVNC_PORT}" "localhost:${VNC_PORT}" &

# --- Launch Claude Desktop ---
# --no-sandbox: Electron's Chromium sandbox cannot init in an unprivileged
# container. The container itself is the sandbox boundary here.
exec gosu "${USER}" env \
  HOME="${HOME}" \
  DISPLAY="${DISPLAY}" \
  DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS}" \
  XDG_RUNTIME_DIR="/tmp/runtime-${USER}" \
  claude-desktop --no-sandbox
