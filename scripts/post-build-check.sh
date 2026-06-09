#!/usr/bin/env bash
set -euo pipefail

repo_bin="${1:-./dictate}"
installed_bin="${2:-$HOME/.local/bin/dictate}"
label="${DICTATE_LAUNCHD_LABEL:-com.user.dictate}"
service="gui/$(id -u)/$label"

fail=0
ok() { printf '[ok] %s\n' "$*"; }
bad() { printf '[fail] %s\n' "$*" >&2; fail=1; }
note() { printf '  %s\n' "$*" >&2; }

check_file() {
  local p="$1" name="$2"
  if [[ -x "$p" ]]; then ok "$name exists: $p"; else bad "$name missing or not executable: $p"; fi
}

check_signature() {
  local p="$1" name="$2"
  local sig ident
  sig="$(codesign -dv "$p" 2>&1 || true)"
  ident="$(printf '%s\n' "$sig" | awk -F= '/^Identifier=/{print $2; exit}')"
  if printf '%s\n' "$sig" | grep -q 'Signature=adhoc'; then
    bad "$name is ad-hoc signed"
    note "run: scripts/make-codesign-cert.sh && make"
  elif [[ "$ident" != "com.user.dictate" ]]; then
    bad "$name has wrong signing identifier: ${ident:-<none>}"
  else
    ok "$name is signed as com.user.dictate"
  fi
}

check_launchagent() {
  local out program state
  out="$(launchctl print "$service" 2>&1 || true)"
  if printf '%s\n' "$out" | grep -q 'Could not find service'; then
    bad "LaunchAgent is not loaded: $service"
    note "run: launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/$label.plist"
    return
  fi
  program="$(printf '%s\n' "$out" | awk -F'= ' '/program = /{print $2; exit}')"
  state="$(printf '%s\n' "$out" | awk -F'= ' '/state = /{print $2; exit}')"
  if [[ "$program" != "$installed_bin" ]]; then
    bad "LaunchAgent program is '$program', expected '$installed_bin'"
  else
    ok "LaunchAgent points at installed binary"
  fi
  if [[ "$state" == "running" ]]; then ok "LaunchAgent is running"; else bad "LaunchAgent state is ${state:-unknown}"; fi
}

check_daemon() {
  local reply
  reply="$("$installed_bin" ping 2>/dev/null || true)"
  if [[ "$reply" == "pong" ]]; then ok "daemon socket replies pong"; else bad "daemon ping failed: ${reply:-<empty>}"; fi
}

check_accessibility() {
  local reply
  reply="$("$installed_bin" axcheck 2>/dev/null || true)"
  if [[ "$reply" == "trusted" ]]; then
    ok "Accessibility is trusted"
  else
    bad "Accessibility is not trusted"
    note "open System Settings -> Privacy & Security -> Accessibility"
    note "add/enable: $installed_bin"
  fi
}

check_file "$repo_bin" "build binary"
check_file "$installed_bin" "installed binary"
check_signature "$repo_bin" "build binary"
check_signature "$installed_bin" "installed binary"
check_launchagent
check_daemon
check_accessibility

if [[ $fail -ne 0 ]]; then
  printf '\npost-build check failed\n' >&2
  exit 1
fi

printf '\npost-build check passed\n'
