#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Optional local workaround for an inconsistent CLT installation; no system edits.
options=()
if [[ -n ${TRANSCRIBER_MANIFEST_OVERLAY:-} ]]; then
  options+=(-Xbuild-tools-swiftc -vfsoverlay -Xbuild-tools-swiftc "$TRANSCRIBER_MANIFEST_OVERLAY")
fi
swift build --build-system native -c release --product transcriber-diarizer "${options[@]}"
bin=$(swift build --build-system native -c release --show-bin-path "${options[@]}")
mkdir -p build/community-1
cp "$bin/transcriber-diarizer" build/community-1/
python3 - "$bin" "$PWD/build/community-1" <<'PYRES'
import plistlib
import shutil
import sys
from pathlib import Path
source, destination = map(Path, sys.argv[1:])
for bundle in source.glob("*.bundle"):
    target = destination / bundle.name
    if target.exists():
        shutil.rmtree(target)  # Generated build output only.
    resources = target / "Contents/Resources"
    shutil.copytree(bundle, resources)
    with (target / "Contents/Info.plist").open("wb") as output:
        plistlib.dump({"CFBundleIdentifier": "local.dictate." + bundle.stem.replace("_", "-"),
                      "CFBundleName": bundle.stem, "CFBundleVersion": "1",
                      "CFBundlePackageType": "BNDL"}, output)
PYRES
