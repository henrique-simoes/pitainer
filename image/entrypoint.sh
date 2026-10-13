#!/bin/bash
# Container entrypoint. Starts as root, closes the network, starts the proxy,
# proves the rules hold, then drops to an unprivileged user. Fails closed: if any
# step fails, nothing else starts.
#
#   entrypoint.sh pi   [pi args...]   run pi as user `pi` (default)
#   entrypoint.sh deps [command...]   run a dependency install as user `deps`
#   entrypoint.sh test                run the acceptance tests and exit
set -euo pipefail

LIB=/usr/local/libexec/pitainer
RUN=/run/pitainer
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MODE="${1:-pi}"
[ $# -gt 0 ] && shift

die() { echo "pitainer: $*" >&2; exit 1; }
[ "$(id -u)" = 0 ] || die "the entrypoint must start as root"

DNS_IP="${PITAINER_DNS:-}"
[[ "$DNS_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "PITAINER_DNS must be an IPv4 address"
WORKDIR="${PITAINER_WORKDIR:-/work}"

# Default gateway (the Mac) from the kernel routing table.
gateway() {
  awk '$2 == "00000000" { h = $3; printf "%d.%d.%d.%d\n", "0x" substr(h,7,2), "0x" substr(h,5,2), "0x" substr(h,3,2), "0x" substr(h,1,2); exit }' /proc/net/route
}
GATEWAY="$(gateway)"
[ -n "$GATEWAY" ] || die "could not determine the default gateway"

# ---------------------------------------------------------------- firewall ---
# Policy is drop. The explicit REJECT at the end only makes blocked connections
# fail fast instead of hanging.
PRIVATE="0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12
         192.0.0.0/24 192.168.0.0/16 198.18.0.0/15 224.0.0.0/4 240.0.0.0/4"

for t in iptables ip6tables; do
  $t -P INPUT DROP; $t -P OUTPUT DROP; $t -P FORWARD DROP
  $t -F; $t -X
  $t -A INPUT -i lo -j ACCEPT
  $t -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  $t -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
done

# Loopback: only pi may use the provider proxy, only deps the package proxy.
# Everything else on loopback is allowed so local test servers keep working.
iptables -A OUTPUT -o lo -p tcp --dport 3128 -m owner ! --uid-owner pi   -j REJECT --reject-with tcp-reset
iptables -A OUTPUT -o lo -p tcp --dport 3129 -m owner ! --uid-owner deps -j REJECT --reject-with tcp-reset
iptables  -A OUTPUT -o lo -j ACCEPT
ip6tables -A OUTPUT -o lo -j ACCEPT

# Private endpoints the user opted into (config key private_endpoint): the proxy
# user may reach exactly these ip:port pairs. Everything else private stays blocked.
ENDPOINTS="$(printf '%s' "${PITAINER_PRIVATE_ENDPOINTS:-}" | tr ', ' '\n\n' | sed '/^$/d')"
for e in $ENDPOINTS; do
  [[ "$e" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+$ ]] || die "private endpoint must be ip:port, got '$e'"
  [ "${e%:*}" = "$GATEWAY" ] && die "private endpoint $e is the Mac itself; that is never allowed"
  iptables -A OUTPUT -m owner --uid-owner pxy -p tcp -d "${e%:*}" --dport "${e##*:}" -j ACCEPT
done

# Off-box: only the proxy user, never to the Mac or any private range.
for net in $PRIVATE; do iptables -A OUTPUT -d "$net" -j REJECT; done
iptables -A OUTPUT -m owner --uid-owner pxy -p udp -d "$DNS_IP" --dport 53  -j ACCEPT
iptables -A OUTPUT -m owner --uid-owner pxy -p tcp -d "$DNS_IP" --dport 53  -j ACCEPT
iptables -A OUTPUT -m owner --uid-owner pxy -p tcp --dport 443 -j ACCEPT
iptables  -A OUTPUT -j REJECT
ip6tables -A OUTPUT -j REJECT

# ------------------------------------------------------------- host lists ---
mkdir -p "$RUN"; chmod 0755 "$RUN"
printf '%s\n' "${PITAINER_PI_HOSTS:-}"   | tr ', ' '\n\n' | sed '/^$/d' > "$RUN/pi.hosts"
printf '%s\n' "${PITAINER_DEPS_HOSTS:-}" | tr ', ' '\n\n' | sed '/^$/d' > "$RUN/deps.hosts"
printf '%s\n' $ENDPOINTS > "$RUN/pi.endpoints"
chmod 0444 "$RUN"/*.hosts "$RUN/pi.endpoints"
echo "nameserver $DNS_IP" > /etc/resolv.conf

# ------------------------------------------------------------ pi settings ---
# The enforced keys always win over the user's own settings, and the file is made
# immutable so pi (and anything running as pi) cannot change the shell or proxy.
AGENT=/home/pi/.pi/agent
mkdir -p "$AGENT" /deps/venvs /deps/cache
chown pi:work /home/pi/.pi "$AGENT"
chown deps:work /deps /deps/venvs /deps/cache; chmod 2775 /deps /deps/venvs /deps/cache
chattr -i "$AGENT/settings.json" 2>/dev/null || true
PITAINER_USER_SETTINGS="${PITAINER_USER_SETTINGS:-}" node -e '
  const fs = require("fs");
  let user = {};
  const raw = process.env.PITAINER_USER_SETTINGS;
  if (raw) { try { user = JSON.parse(raw); } catch (e) { console.error("pitainer: settings.json is not valid JSON: " + e.message); process.exit(1); } }
  const enforced = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  for (const k of ["shellCommandPrefix", "npmCommand", "extensions", "packages"]) delete user[k];
  fs.writeFileSync(process.argv[2], JSON.stringify({ ...user, ...enforced }, null, 2) + "\n");
' "$LIB/settings.json" "$AGENT/settings.json"
chown root:root "$AGENT/settings.json"; chmod 0444 "$AGENT/settings.json"
chattr +i "$AGENT/settings.json" || die "could not make pi's settings immutable (is LINUX_IMMUTABLE granted?)"

# Three more places in pi's folder can make pi run code as the `pi` user, outside
# the offline shell: user extensions, MCP server commands, and `!command` values
# in models.json. Extensions and MCP are closed; models.json is frozen as the
# user imported it (`pitainer models import`).
chattr -i "$AGENT/extensions" "$AGENT/mcp.json" 2>/dev/null || true
rm -rf "$AGENT/extensions" "$AGENT/mcp.json"
mkdir "$AGENT/extensions"; chown root:root "$AGENT/extensions"; chmod 0755 "$AGENT/extensions"
printf '{ "mcpServers": {} }\n' > "$AGENT/mcp.json"; chown root:root "$AGENT/mcp.json"; chmod 0444 "$AGENT/mcp.json"
chattr +i "$AGENT/extensions" "$AGENT/mcp.json" || die "could not lock pi's extension and MCP configuration"
if [ -e "$AGENT/models.json" ]; then
  chattr -i "$AGENT/models.json" 2>/dev/null || true
  chown pi:work "$AGENT/models.json"; chmod 0400 "$AGENT/models.json"
else
  # An empty, frozen file: pi cannot create one with a `!command` in it later.
  printf '{ "providers": {} }\n' > "$AGENT/models.json"; chown pi:work "$AGENT/models.json"; chmod 0400 "$AGENT/models.json"
fi
chattr +i "$AGENT/models.json" || die "could not lock pi's models.json"

# ------------------------------------------------------------------ proxy ---
touch "$RUN/proxy.log"; chown pxy "$RUN/proxy.log"
setpriv --reuid pxy --regid pxy --clear-groups --no-new-privs --bounding-set -all \
  node "$LIB/proxy.js" 2>>"$RUN/proxy.log" &
for _ in $(seq 1 50); do
  grep -q 'LISTEN deps' "$RUN/proxy.log" 2>/dev/null && break
  sleep 0.1
done
grep -q 'LISTEN deps' "$RUN/proxy.log" || die "the proxy did not start: $(cat "$RUN/proxy.log")"

# ------------------------------------------------------------ privileges ---
# Keep only what sudo needs for the pi -> tools switch. NET_ADMIN and
# LINUX_IMMUTABLE leave the bounding set, so not even a setuid-root program can
# touch the firewall or pi's settings after this point.
BOUND="-all,+setuid,+setgid,+audit_write"
as() {  # as <user> <command...>
  local u="$1"; shift
  setpriv --reuid "$u" --regid work --init-groups --inh-caps -all --bounding-set "$BOUND" "$@"
}

first_host() { grep -v '\*' "$1" | head -1; }
selftest() {
  local ok=0
  export PITAINER_SELFTEST_SOFT="${PITAINER_SELFTEST_SOFT:-0}"
  as tools env HOME=/home/tools node "$LIB/selftest.js" tools "$DNS_IP" "$GATEWAY" || ok=1
  as pi    env HOME=/home/pi    node "$LIB/selftest.js" pi    "$DNS_IP" "$GATEWAY" "$(first_host "$RUN/pi.hosts")" || ok=1
  as deps  env HOME=/home/deps  node "$LIB/selftest.js" deps  "$DNS_IP" "$GATEWAY" "$(first_host "$RUN/deps.hosts")" || ok=1
  return $ok
}

umask 002
cd "$WORKDIR" 2>/dev/null || die "working folder $WORKDIR does not exist in the container"

case "$MODE" in
  pi)
    PITAINER_SELFTEST_SOFT=1 selftest > "$RUN/selftest.log" 2>&1 || { cat "$RUN/selftest.log" >&2; die "network self-test failed; pi was not started"; }
    grep '^WARN' "$RUN/selftest.log" >&2 || true
    exec setpriv --reuid pi --regid work --init-groups --inh-caps -all --bounding-set "$BOUND" \
      env -u PITAINER_USER_SETTINGS -u PITAINER_PI_HOSTS -u PITAINER_DEPS_HOSTS -u PITAINER_PRIVATE_ENDPOINTS \
      HOME=/home/pi USER=pi LOGNAME=pi PI_OFFLINE=1 PI_SKIP_VERSION_CHECK=1 \
      pi --no-approve "$@"
    ;;
  deps)
    PITAINER_SELFTEST_SOFT=1 selftest > "$RUN/selftest.log" 2>&1 || { cat "$RUN/selftest.log" >&2; die "network self-test failed; nothing was run"; }
    exec setpriv --reuid deps --regid work --init-groups --inh-caps -all --bounding-set -all --no-new-privs \
      env -i HOME=/home/deps USER=deps LOGNAME=deps TERM="${TERM:-xterm}" PATH="$PATH" \
      HTTPS_PROXY=http://127.0.0.1:3129 https_proxy=http://127.0.0.1:3129 \
      PIP_CACHE_DIR=/deps/cache/pip npm_config_cache=/deps/cache/npm UV_CACHE_DIR=/deps/cache/uv \
      "$LIB/deps-run" "$@"
    ;;
  test)
    export DNS_IP GATEWAY BOUND
    . "$LIB/acceptance.sh"
    ;;
  *) die "unknown mode: $MODE" ;;
esac
