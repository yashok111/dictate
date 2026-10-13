#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
fixture_dir=$(mktemp -d)
python3 tests/http_model_server.py "$fixture_dir/address" &
fixture_pid=$!
cleanup() {
	kill "$fixture_pid" 2>/dev/null || true
	wait "$fixture_pid" 2>/dev/null || true
	rm -rf "$fixture_dir"
}
trap cleanup EXIT
for ((attempt = 0; attempt < 100; attempt++)); do
	[[ -s "$fixture_dir/address" ]] && break
	sleep 0.05
done
export TRANSCRIBER_TEST_HTTP
TRANSCRIBER_TEST_HTTP=$(cat "$fixture_dir/address")
bash scripts/test-swift.sh
