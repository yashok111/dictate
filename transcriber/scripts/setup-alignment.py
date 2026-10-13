"""Provision pinned native ONNX Runtime, headers and the Russian alignment model."""
import hashlib
import json
import os
import shutil
import tarfile
from pathlib import Path
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[1]
DEPS = ROOT / ".deps"


def fetch(url, path, expected):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists() and hashlib.sha256(path.read_bytes()).hexdigest() == expected:
        return
    temporary = path.with_suffix(path.suffix + ".part")
    try:
        with urlopen(url, timeout=120) as source, temporary.open("wb") as target:
            shutil.copyfileobj(source, target)
        if hashlib.sha256(temporary.read_bytes()).hexdigest() != expected:
            raise RuntimeError(f"Checksum mismatch: {path.name}")
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def main():
    headers = {
        "onnxruntime_c_api.h": "d683537d0fdc29e977b5520f7f15d87a0ac212ae6d94fa9be8893a52655621ae",
        "onnxruntime_cxx_api.h": "28b21dfc371fb53d1ba67356adeb124f36643ee5ab6f1ad2e9afbf09eb4bf305",
        "onnxruntime_cxx_inline.h": "c41b9a11aac46851f68f4bd888bb2444a0e1eb6b37eadb41bf15f5154b48ea31",
        "onnxruntime_float16.h": "6c4db3d1954b266c4febe413351af86cac922e3448538e7e452e51d646e56a4a",
    }
    for name, checksum in headers.items():
        fetch(f"https://raw.githubusercontent.com/microsoft/onnxruntime/v1.22.0/include/onnxruntime/core/session/{name}", DEPS / "onnxruntime" / name, checksum)
    # Only ONNX Runtime is extracted; sherpa's inference libraries are not shipped.
    filename = "sherpa-onnx-v1.13.8-osx-arm64-shared-no-tts-lib.tar.bz2"
    archive = DEPS / "downloads" / filename
    fetch(f"https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.8/{filename}", archive,
          "f3e0cbd86cc3f38dad30c97921b40e9a8bcc6f2c943777eb76ad77176993e417")
    with tarfile.open(archive) as source:
        name = "sherpa-onnx-v1.13.8-osx-arm64-shared-no-tts-lib/lib/libonnxruntime.dylib"
        # Extract beside the target and rename over it: an interrupted extraction must never
        # leave a truncated dylib for the next `make worker` to link against.
        final = DEPS / "onnxruntime/libonnxruntime.dylib"
        part = final.with_name(final.name + ".part")
        member = source.getmember(name)
        with source.extractfile(member) as data, part.open("wb") as target:
            shutil.copyfileobj(data, target)
        if part.stat().st_size != member.size:
            part.unlink(missing_ok=True)
            raise RuntimeError("libonnxruntime.dylib extraction is truncated")
        os.replace(part, final)
    catalog = json.loads((ROOT / "Resources/models.json").read_text())
    artifact = next(a for a in catalog["artifacts"] if a["id"] == "alignment-ru")
    fetch(artifact["url"], ROOT / ".models/alignment-ru.onnx", artifact["downloadSHA256"])
    print("Verified native alignment runtime and model")


if __name__ == "__main__":
    main()
