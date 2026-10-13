#!/bin/bash
set -euo pipefail
app=${1:?Usage: sign-app.sh APP --mode adhoc|developer-id}
shift
[[ ${1:-} == --mode && $# == 2 ]] || {
	echo 'Expected --mode adhoc|developer-id' >&2
	exit 2
}
mode=$2
case "$mode" in
adhoc)
	identity=-
	options=()
	;;
developer-id)
	identity=${TRANSCRIBER_SIGN_IDENTITY:?Set TRANSCRIBER_SIGN_IDENTITY}
	options=(--timestamp --options runtime)
	;;
*)
	echo 'Unknown signing mode' >&2
	exit 2
	;;
esac
python3 - "$app" "$identity" "${options[@]}" <<'PY'
import subprocess
import sys
from pathlib import Path

app, identity = Path(sys.argv[1]), sys.argv[2]
options = sys.argv[3:]
magic = {b'\xcf\xfa\xed\xfe', b'\xce\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'}
for bundle in sorted(app.rglob('*.bundle'), key=lambda p: len(p.parts), reverse=True):
    subprocess.run(['codesign', '--force', '--sign', identity, *options, str(bundle)], check=True)
for path in sorted(app.rglob('*'), key=lambda p: len(p.parts), reverse=True):
    if path.is_file() and not path.is_symlink():
        with path.open('rb') as source:
            macho = source.read(4) in magic
        if macho:
            subprocess.run(['codesign', '--force', '--sign', identity, *options, str(path)], check=True)
subprocess.run(['codesign', '--force', '--sign', identity, *options, str(app)], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
PY
