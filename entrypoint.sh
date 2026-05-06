#!/usr/bin/env bash
set -euo pipefail

: "${DISPLAY:=:1}"
: "${SCREEN_GEOMETRY:=1440x900x24}"
: "${KASMVNC_PORT:=8444}"
: "${USER:=claude}"
: "${HOME:=/home/claude}"
: "${PUID:=1000}"
: "${PGID:=1000}"
: "${TZ:=UTC}"
: "${VNC_PASSWORD:=}"
: "${VNC_USERNAME:=kasm_user}"

# --- Timezone ---
if [ -f "/usr/share/zoneinfo/${TZ}" ]; then
  ln -snf "/usr/share/zoneinfo/${TZ}" /etc/localtime
  echo "${TZ}" > /etc/timezone
fi

# --- Align user UID/GID with TrueNAS dataset owner ---
if [ "$(id -u "${USER}")" != "${PUID}" ] || [ "$(id -g "${USER}")" != "${PGID}" ]; then
  groupmod -o -g "${PGID}" "${USER}"
  usermod  -o -u "${PUID}" -g "${PGID}" "${USER}"
fi

# Always make sure $HOME and the standard XDG dirs exist and are writable by
# the runtime user. We chown $HOME non-recursively (a recursive chown across
# the bind-mounted .config/Claude can be slow or partially fail on some ZFS
# datasets) and use `install -d` to create each xdg subdir with the correct
# ownership in a single syscall.
chown "${PUID}:${PGID}" "${HOME}"
for d in .cache .config .local .local/share .local/state .vnc; do
  install -d -m 0755 -o "${PUID}" -g "${PGID}" "${HOME}/${d}"
done
install -d -m 0700 -o "${PUID}" -g "${PGID}" "/tmp/runtime-${USER}"
install -d -m 0755 -o "${PUID}" -g "${PGID}" "${HOME}/.config/Claude"

# Best-effort chown on the bind-mount target. If the host dataset owner is
# already 568:568 this is a no-op; otherwise it fixes up files Claude Desktop
# wrote during a prior run with a different PUID. Don't let a partial failure
# kill the entrypoint — the user can chown the dataset host-side instead.
chown -R "${PUID}:${PGID}" "${HOME}/.config/Claude" 2>/dev/null || true

# --- Clean stale X locks (image restart leaves these behind) ---
rm -f /tmp/.X1-lock /tmp/.X11-unix/X1 || true
mkdir -p /tmp/.X11-unix && chmod 1777 /tmp/.X11-unix

# --- KasmVNC config ---
# Resolution: split SCREEN_GEOMETRY (e.g. "1920x1080x24") into width/height/depth.
SCREEN_W="${SCREEN_GEOMETRY%%x*}"
SCREEN_REST="${SCREEN_GEOMETRY#*x}"
SCREEN_H="${SCREEN_REST%%x*}"
SCREEN_D="${SCREEN_REST##*x}"

# Per-user kasmvnc.yaml. KasmVNC reads this on Xvnc start. We pin the
# websocket port to a single value (rather than the default 8443+display) so
# the container exposes a predictable port regardless of which display number
# vncserver picks.
cat > "${HOME}/.vnc/kasmvnc.yaml" <<EOF
network:
  protocol: http
  websocket_port: ${KASMVNC_PORT}
  ssl:
    require_ssl: false
    pem_certificate: /etc/ssl/certs/ssl-cert-snakeoil.pem
    pem_key: /etc/ssl/private/ssl-cert-snakeoil.key
desktop:
  resolution:
    width: ${SCREEN_W}
    height: ${SCREEN_H}
  allow_resize: true
EOF
# NOTE on TLS: we set require_ssl=false and protocol=http so the container
# serves plain HTTP/WS on KASMVNC_PORT. This is the right default for a
# homelab behind a reverse proxy that terminates TLS itself, and avoids the
# self-signed-cert click-through. If you expose this port directly to an
# untrusted network, put a TLS-terminating proxy (Caddy, Traefik, nginx) in
# front, or flip require_ssl back to true and accept the snakeoil warning.

# --- Authentication: KasmVNC BasicAuth ---
# KasmVNC's web UI uses BasicAuth via ~/.kasmpasswd. If VNC_PASSWORD is set,
# write a single user (VNC_USERNAME) with read+write access. If empty, refuse
# to start: KasmVNC will fail-open without auth and that's a footgun for a
# port-forwarded homelab service.
if [ -z "${VNC_PASSWORD}" ]; then
  echo "FATAL: VNC_PASSWORD is empty. Set it in the compose env to enable" >&2
  echo "BasicAuth on the KasmVNC web UI. Refusing to start without auth." >&2
  exit 1
fi
# `kasmvncpasswd -u <user> -w` reads the password twice from stdin and writes
# it (with read+write perms by default) into ~/.kasmpasswd. Pass the password
# through an exported env var rather than interpolating it into a shell
# command, so passwords containing quotes or shell metacharacters round-trip
# safely.
# gosu inherits the parent environment, so the exported vars are visible in
# the inner shell without any flag like sudo's -E.
export VNC_PASSWORD VNC_USERNAME
# shellcheck disable=SC2016  # vars are intentionally expanded by the inner shell
gosu "${USER}" sh -c \
  'printf "%s\n%s\n" "$VNC_PASSWORD" "$VNC_PASSWORD" | kasmvncpasswd -u "$VNC_USERNAME" -w' \
  >/dev/null

chown -R "${PUID}:${PGID}" "${HOME}/.vnc" "${HOME}/.kasmpasswd" 2>/dev/null || true

# --- xstartup: launched by Xvnc as the runtime user ---
# Starts the D-Bus session bus (Electron/GTK want it) and the openbox WM.
# claude-desktop is launched separately at the end of this script so its
# lifecycle == the container's lifecycle.
cat > "${HOME}/.vnc/xstartup" <<'EOF'
#!/usr/bin/env bash
set -e
unset SESSION_MANAGER DBUS_SESSION_BUS_ADDRESS
eval "$(dbus-launch --sh-syntax)"
export DBUS_SESSION_BUS_ADDRESS DBUS_SESSION_BUS_PID
openbox --config-file /etc/xdg/openbox/rc.xml &
# Keep xstartup alive so Xvnc treats the session as active.
exec tail -f /dev/null
EOF
chmod 0755 "${HOME}/.vnc/xstartup"
chown "${PUID}:${PGID}" "${HOME}/.vnc/xstartup" "${HOME}/.vnc/kasmvnc.yaml"

# --- Start KasmVNC ---
# vncserver daemonizes Xvnc + the web server. -fg would foreground it but then
# we can't exec claude-desktop afterward; instead we let it daemonize, wait
# for the X socket, then exec claude-desktop in the foreground so the
# container's PID 1 tracks it (when claude-desktop dies the container exits).
# vncserver daemonizes Xvnc and the bundled web server. We pass the display,
# geometry, depth, websocket port, and bind interface explicitly. With a
# user-provided ~/.vnc/xstartup present, vncserver runs that and skips its own
# desktop-environment autoselect — no -select-de needed.
gosu "${USER}" vncserver "${DISPLAY}" \
  -geometry "${SCREEN_W}x${SCREEN_H}" \
  -depth "${SCREEN_D}" \
  -websocketPort "${KASMVNC_PORT}" \
  -interface 0.0.0.0

# Wait for the X socket the new Xvnc just created.
for _ in $(seq 1 50); do
  if [ -S /tmp/.X11-unix/X1 ]; then break; fi
  sleep 0.1
done

# --- Launch Claude Desktop ---
# --no-sandbox: Electron's Chromium sandbox cannot init in an unprivileged
# container. The container itself is the sandbox boundary here.
exec gosu "${USER}" env \
  HOME="${HOME}" \
  USER="${USER}" \
  LOGNAME="${USER}" \
  DISPLAY="${DISPLAY}" \
  XDG_RUNTIME_DIR="/tmp/runtime-${USER}" \
  XDG_CACHE_HOME="${HOME}/.cache" \
  XDG_CONFIG_HOME="${HOME}/.config" \
  XDG_DATA_HOME="${HOME}/.local/share" \
  XDG_STATE_HOME="${HOME}/.local/state" \
  PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  claude-desktop --no-sandbox
