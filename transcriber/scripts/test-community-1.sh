#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
root=$(mktemp -d /private/tmp/community-1-smoke.XXXXXX)
# Remove the working directory on success; keep it (and say where) when the smoke fails.
# shellcheck disable=SC2154  # `status` is assigned inside the trap string itself
trap 'status=$?; if [[ $status -eq 0 ]]; then rm -rf "$root"; else echo "kept for inspection: $root" >&2; fi' EXIT
model=${1:-.models/community-1}
manifest="$PWD/Resources/community-1.lock.json"
helper="$PWD/build/community-1/transcriber-diarizer"
# Synthetic audio tests integration only, not real meeting diarization accuracy.
say -v Milena -o "$root/source.aiff" 'Сегодня проверяем расшифровку. Все модели работают локально. Продолжим обсуждение после небольшой паузы.'
build/transcriber-worker --prepare "$root/source.aiff" .models/ggml-large-v3-turbo-q5_0.bin "$root" > "$root/prepare.events" 2> "$root/prepare.log"
"$helper" --attempt-dir "$root" --model-dir "$model" --model-manifest "$manifest" --cache-dir "$root/cache" > "$root/speakers.events" 2> "$root/speakers.log"
build/transcriber-worker --finalize "$root"
"$helper" --attempt-dir "$root" --model-dir "$model" --model-manifest "$manifest" --cache-dir "$root/cache" > "$root/cached.events" 2> "$root/cached.log"
python3 - "$root" <<'PY'
import hashlib, json, sys
from pathlib import Path
root = Path(sys.argv[1])
doc = json.loads((root / 'transcript.json').read_text())
assert doc['diarization']['engine'] == 'community-1-fluidaudio'
assert doc['segments'], 'No transcription'
assert 'step=0.1 exclusive=false' in (root / 'speakers.log').read_text()
assert 'minimum=0.5 zeroVote=true' in (root / 'speakers.log').read_text()
# 0.2.1 speaker turns must not be reused after changing the inference settings.
previous = 'offline-v1;step=0.1;exclusive=false;embeddingSkip=none;otherDefaults=04e363c29d9a754022d602d6fe1468ab80a0f705'
assert doc['diarization']['configurationSHA256'] != hashlib.sha256(previous.encode()).hexdigest()
assert 'speaker-cache: hit' in (root / 'cached.log').read_text()
print('Community-1 smoke passed')
PY
