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
step "install → $installed"
mkdir -p "$(dirname "$installed")"
cp "$bin" "$installed"
printf 'copied %s → %s\n' "$bin" "$installed"

# 4. Restart the LaunchAgent so the new binary is picked up. kickstart -k restarts a loaded service;
#    if it isn't loaded yet, bootstrap it from the installed plist.
step "restart LaunchAgent ($service)"
if launchctl print "$service" >/dev/null 2>&1; then
  launchctl kickstart -k "$service"
  printf 'kickstarted %s\n' "$service"
elif [[ -f "$plist" ]]; then
  launchctl bootstrap "gui/$(id -u)" "$plist"
  printf 'bootstrapped %s\n' "$service"
else
  printf 'warning: %s not loaded and no plist at %s — skipping restart\n' "$service" "$plist" >&2
  printf '  install it: sed "s|/Users/YOUR_USERNAME|$HOME|" com.user.dictate.plist > %s\n' "$plist" >&2
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
