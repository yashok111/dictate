"""Write metadata for a developer bundle using this checkout's local models."""

import argparse
import json
import plistlib
import shutil
from pathlib import Path

root = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("bundle", type=Path)
parser.add_argument("--mode", choices=["development", "release"], default="development")
args = parser.parse_args()
bundle = args.bundle
with (bundle / "Contents/Info.plist").open("wb") as target:
    plistlib.dump(
        {
            "CFBundleExecutable": "Transcriber",
            "CFBundleIdentifier": "local.dictate.transcriber",
            "CFBundleName": "Расшифровки",
            "CFBundleIconFile": "AppIcon",
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "7",
            "CFBundleShortVersionString": "0.2.5",
            "LSMinimumSystemVersion": "26.0" if args.mode == "release" else "13.0",
            "NSHighResolutionCapable": True,
        },
        target,
    )

# Provisional admission budgets: local peaks were ~1.04 GB (Turbo Q5 RSS)
# and ~3.91 GB (large-v3 footprint). Include processing margin here;
# MemoryPolicy adds a separate 0.5 GB reserve. Still not release-qualified.
# Community-1 measured ~246 MB peak on a short clip. Keep a provisional 3 GB
# floor for long-recording PCM copies and clustering; not a measured 4-hour bound.
# Local developer model packs are provisioned by setup scripts.
config = {
    "alignmentModel": str(root / ".models/alignment-ru.onnx"),
    "vad": str(root / ".deps/downloads/ggml-silero-v6.2.0.bin"),
    "diarizationModelDirectory": str(root / ".models/community-1"),
    "diarizationManifest": str(root / "Resources/community-1.lock.json"),
    "profiles": [
        {
            "id": "economy",
            "title": "Экономный",
            "path": str(root / ".models/ggml-small-q5_1.bin"),
            "peakBytes": 3_000_000_000,
            "rank": 1,
        },
        {
            "id": "quality",
            "title": "Быстрый · Turbo Q5",
            "path": str(root / ".models/ggml-large-v3-turbo-q5_0.bin"),
            "peakBytes": 3_000_000_000,
            "rank": 2,
        },
        {
            "id": "turbo-fp16",
            "title": "Turbo · без сжатия (FP16)",
            "path": str(root / ".models/ggml-large-v3-turbo.bin"),
            "peakBytes": 3_000_000_000,
            "rank": 2,
            "automatic": False,
        },
        {
            "id": "large-v3",
            "title": "Полный · large-v3",
            "path": str(root / ".models/ggml-large-v3.bin"),
            "peakBytes": 4_500_000_000,
            "rank": 3,
            "automatic": False,
        },
    ],
}
if args.mode == "release":
    config = {"mode": "managed", "catalog": "models.json"}
    shutil.copyfile(
        root / "Resources/models.json", bundle / "Contents/Resources/models.json"
    )
(bundle / "Contents/Resources/runtime.json").write_text(
    json.dumps(config, indent=2, ensure_ascii=False)
)

shutil.copyfile(root / "Resources/community-1.lock.json", bundle / "Contents/Resources/community-1.lock.json")
