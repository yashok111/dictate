#!/usr/bin/env bash
# Deploy dictate: build → unit-test → install → restart the LaunchAgent → post-build checks.
# One command replaces the manual `make && cp … && launchctl kickstart -k …` dance.
#
#   scripts/deploy.sh                 # full deploy (tests + checks)
#   scripts/deploy.sh --no-test       # skip `make test` (faster inner loop)
#   scripts/deploy.sh --no-check      # skip the post-build verification
#   scripts/deploy.sh --no-test --no-check
#
# Honors the same env as the rest of the repo: DICTATE_LAUNCHD_LABEL (default com.user.dictate).
set -euo pipefail

cd "$(dirname "$0")/.."   # repo root, so relative paths (./dictate, scripts/…) resolve

run_test=1
run_check=1
for arg in "$@"; do
  case "$arg" in
    --no-test)  run_test=0 ;;
    --no-check) run_check=0 ;;
    -h|--help)  sed -n '2,12p' "$0"; exit 0 ;;
    *) printf 'unknown option: %s (see --help)\n' "$arg" >&2; exit 2 ;;
  esac
done

bin="./dictate"
installed="$HOME/.local/bin/dictate"
label="${DICTATE_LAUNCHD_LABEL:-com.user.dictate}"
service="gui/$(id -u)/$label"
plist="$HOME/Library/LaunchAgents/$label.plist"

step() { printf '\n\033[1m▶ %s\033[0m\n' "$*"; }

# 1. Unit tests (pure logic) — cheap, host c++, no whisper/mic. Fail fast before touching the daemon.
if [[ $run_test -eq 1 ]]; then
  step "make test"
  make test
fi

# 2. Build + sign the daemon binary.
step "make"
make

# 3. Install into ~/.local/bin (the LaunchAgent runs THIS copy, not the repo build — gotcha #13).
#    Copy beside it, then rename over it: a new inode swapped in atomically. An in-place `cp`
#    rewrote the image the running daemon has mapped (macOS may kill it for an invalid code
#    signature) and a Ctrl-C mid-copy left a truncated binary for KeepAlive to crash-loop on.
step "install → $installed"
mkdir -p "$(dirname "$installed")"
cp "$bin" "$installed.new"
mv -f "$installed.new" "$installed"
printf 'installed %s → %s\n' "$bin" "$installed"

# The daemon's socket and logs live in this owner-only directory; launchd opens the log path in
# the plist itself, so it must exist before the agent starts. (-m applies to the deepest dir
# only — the one that must be private.)
# shellcheck disable=SC2174
mkdir -p -m 700 "$HOME/.local/share/dictate"

# 4. Install the LaunchAgent plist from the repo template, then restart the agent. launchd keeps
#    the environment it was bootstrapped with, so a CHANGED plist needs bootout + bootstrap — a
#    kickstart alone would keep running with the old settings (watchdog, idle-unload, log path).
#    An unchanged plist on a loaded service just gets kickstart -k for the new binary.
step "restart LaunchAgent ($service)"
rendered="$(mktemp)"
trap 'rm -f "$rendered"' EXIT
sed "s|/Users/YOUR_USERNAME|$HOME|g" com.user.dictate.plist > "$rendered"
plist_changed=0
if [[ "$label" == "com.user.dictate" ]] && ! cmp -s "$rendered" "$plist"; then
  mkdir -p "$(dirname "$plist")"
  cp "$rendered" "$plist.new" && mv -f "$plist.new" "$plist"   # never a half-written plist
  plist_changed=1
  printf 'installed plist → %s\n' "$plist"
fi
if launchctl print "$service" >/dev/null 2>&1; then
  if [[ $plist_changed -eq 1 ]]; then
    launchctl bootout "$service" || true
    launchctl bootstrap "gui/$(id -u)" "$plist"
    printf 're-bootstrapped %s (plist changed)\n' "$service"
  else
    launchctl kickstart -k "$service"
    printf 'kickstarted %s\n' "$service"
  fi
elif [[ -f "$plist" ]]; then
  launchctl bootstrap "gui/$(id -u)" "$plist"
  printf 'bootstrapped %s\n' "$service"
else
  printf 'warning: %s not loaded and no plist at %s — skipping restart\n' "$service" "$plist" >&2
fi

# 5. Post-build verification (binary, signature, LaunchAgent, daemon ping, Accessibility).
if [[ $run_check -eq 1 ]]; then
  step "post-build check"
  # Wait for the daemon to reload the model + ggml backends and rebind the socket before checking
  # (cold start can take several seconds — the client itself polls ~6 s for this window).
  printf 'waiting for daemon to come up'
  for _ in $(seq 1 40); do
    [[ "$("$installed" ping 2>/dev/null || true)" == "pong" ]] && { printf ' up\n'; break; }
    printf '.'; sleep 0.5
  done
  scripts/post-build-check.sh "$bin" "$installed"
fi

printf '\n\033[1;32m✓ deploy complete\033[0m\n'
