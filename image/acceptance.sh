# Acceptance tests. Sourced by entrypoint.sh in `test` mode, as root, after the
# firewall and proxy are up. Prints PASS/FAIL lines and exits non-zero on any FAIL.
set +e
FAILED=0
ok()   { echo "PASS $*"; }
bad()  { echo "FAIL $*"; FAILED=1; }
want_fail() { local label="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$label"; else ok "$label"; fi; }
want_ok()   { local label="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$label"; else bad "$label"; fi; }
SHELL_WRAPPER="$LIB/tool-shell"

echo "== network, per user"
selftest || FAILED=1
[ -n "${PITAINER_PRIVATE_ENDPOINTS:-}" ] && echo "note: private endpoints are open to pi: $PITAINER_PRIVATE_ENDPOINTS"
setpriv --reuid pxy --regid pxy --clear-groups --no-new-privs --bounding-set -all \
  node "$LIB/selftest.js" pxy "$DNS_IP" "$GATEWAY" || FAILED=1

echo "== offline shell"
who="$(as pi "$SHELL_WRAPPER" -c 'id -un' 2>/dev/null)"
[ "$who" = tools ] && ok "[pi] commands run as tools" || bad "[pi] commands run as '$who', want tools"
env_leak="$(as pi env ANTHROPIC_API_KEY=secret "$SHELL_WRAPPER" -c 'echo "${ANTHROPIC_API_KEY:-}"' 2>/dev/null)"
[ -z "$env_leak" ] && ok "[tools] does not inherit pi's API keys" || bad "[tools] inherited an API key"
venv_cmd="$(as pi "$SHELL_WRAPPER" -c 'echo ran' 2>/dev/null)"
[ "$venv_cmd" = ran ] && ok "[pi] wrapper passes -c commands through" || bad "[pi] wrapper did not run the command"

echo "== privilege"
want_fail "[pi] cannot become root"                 as pi sudo -n true
want_fail "[pi] cannot run a plain shell as tools"  as pi sudo -n -u tools /bin/bash -c true
want_fail "[tools] cannot use sudo"                 as tools sudo -n true
for u in pi tools deps; do
  want_fail "[$u] cannot list firewall rules"   as "$u" iptables -S
  want_fail "[$u] cannot flush firewall rules"  as "$u" iptables -F
done
want_fail "[tools via wrapper] cannot flush firewall rules" as pi "$SHELL_WRAPPER" -c 'iptables -F'
iptables -S OUTPUT | grep -q -- '-P OUTPUT DROP' && ok "firewall policy is still drop" || bad "firewall policy changed"

echo "== pi settings"
S=/home/pi/.pi/agent/settings.json
want_fail "[pi] cannot edit settings"     as pi sh -c "echo x >> $S"
want_fail "[pi] cannot replace settings"  as pi sh -c "rm -f $S || mv $S $S.bak"
want_fail "[tools] cannot edit settings"  as tools sh -c "echo x >> $S"
want_fail "[pi] cannot edit the wrapper"  as pi sh -c "echo x >> $SHELL_WRAPPER"
for key in '"shellPath": "/usr/local/libexec/pitainer/tool-shell"' '"httpProxy": "http://127.0.0.1:3128"' '"defaultProjectTrust": "never"' '"enableInstallTelemetry": false'; do
  grep -qF "$key" "$S" && ok "settings enforce $key" || bad "settings missing $key"
done
want_ok "[pi] pi starts" as pi env HOME=/home/pi PI_OFFLINE=1 PI_SKIP_VERSION_CHECK=1 pi --version

A=/home/pi/.pi/agent
want_fail "[pi] cannot add an extension"        as pi sh -c "echo x > $A/extensions/x.ts"
want_fail "[pi] cannot replace the extensions folder" as pi sh -c "rm -rf $A/extensions || mv $A/extensions $A/e2"
want_fail "[pi] cannot edit MCP servers"        as pi sh -c "echo x >> $A/mcp.json || rm -f $A/mcp.json"
want_fail "[pi] cannot edit models.json"        as pi sh -c "echo x >> $A/models.json || rm -f $A/models.json"
want_ok   "[pi] can read models.json"           as pi cat "$A/models.json"
want_fail "[tools] cannot read models.json"     as tools cat "$A/models.json"
want_fail "[tools] cannot read pi's logins"     as tools sh -c "cat $A/auth.json 2>/dev/null; ls $A/sessions"

echo "== firewall rules present"
for net in 10.0.0.0/8 100.64.0.0/10 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16; do
  want_ok "private range $net is rejected for every user" iptables -C OUTPUT -d "$net" -j REJECT
done
want_ok "IPv6 output is rejected" ip6tables -C OUTPUT -j REJECT
case "$GATEWAY" in 10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|100.6[4-9].*|100.[7-9]?.*|100.1[01]?.*|100.12[0-7].*) ok "the Mac's address $GATEWAY is inside a rejected range" ;; *) bad "the Mac's address $GATEWAY is not covered by a rejected range" ;; esac

echo "== mounts"
host_mounts="$(awk '$3 == "virtiofs" { print $2 }' /proc/mounts)"
outside="$(printf '%s\n' "$host_mounts" | grep -v '^/work/' | grep -v '^$')"
[ -z "$outside" ] && ok "host folders appear only under /work" || bad "host folder mounted outside /work: $outside"
for m in $(printf '%s\n' "$host_mounts" | grep '^/work/'); do
  if awk -v m="$m" '$2 == m { print $4 }' /proc/mounts | grep -qE '(^|,)ro(,|$)'; then
    want_fail "[tools] cannot write to read-only $m" as tools touch "$m/.pitainer-test.$$"
    continue
  fi
  f="$m/.pitainer-test.$$"
  as pi    sh -c "umask 002; echo pi > '$f'"      2>/dev/null
  as tools sh -c "umask 002; echo tools >> '$f'"  2>/dev/null
  as deps  sh -c "umask 002; echo deps >> '$f'"   2>/dev/null
  [ "$(tr '\n' ' ' < "$f" 2>/dev/null)" = "pi tools deps " ] && ok "pi, tools and deps share files in $m" || bad "users cannot share files in $m"
  as tools rm -f "$f" 2>/dev/null; [ ! -e "$f" ] && ok "[tools] can delete a file pi created in $m" || { bad "[tools] cannot delete pi's file in $m"; rm -f "$f"; }
done

echo
[ "$FAILED" = 0 ] && echo "ALL TESTS PASSED" || echo "SOME TESTS FAILED"
exit "$FAILED"
