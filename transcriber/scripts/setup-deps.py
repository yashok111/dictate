"""Fetch pinned development dependencies; never called by the app."""

import hashlib
import json
import shutil
from pathlib import Path
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[1]
DEPS = ROOT / ".deps"
SOURCES = [
    (artifact["url"], artifact["downloadSHA256"])
    for artifact in json.loads((ROOT / "Resources/models.json").read_text())[
        "artifacts"
    ]
    if artifact["id"] in {"silero"}
]


def digest(path):
    with path.open("rb") as data:
        return hashlib.file_digest(data, "sha256").hexdigest()


def main():
    import runpy
    runpy.run_path(str(ROOT / "scripts/setup-community-1.py"), run_name="__main__")
    runpy.run_path(str(ROOT / "scripts/setup-alignment.py"), run_name="__main__")
    downloads = DEPS / "downloads"
    downloads.mkdir(parents=True, exist_ok=True)
    for url, expected in SOURCES:
        destination = downloads / url.rsplit("/", 1)[1]
        if not destination.exists():
            print(f"Downloading {destination.name}", flush=True)
            partial = destination.with_suffix(destination.suffix + ".part")
            try:
                with urlopen(url, timeout=60) as source, partial.open("wb") as target:
                    shutil.copyfileobj(source, target)
                if digest(partial) != expected:
                    raise RuntimeError(f"SHA-256 mismatch: {destination.name}")
                partial.replace(destination)
            finally:
                partial.unlink(missing_ok=True)
        if digest(destination) != expected:
            raise RuntimeError(
                f"SHA-256 mismatch: {destination.name}; remove it and retry"
            )



if __name__ == "__main__":
    main()
