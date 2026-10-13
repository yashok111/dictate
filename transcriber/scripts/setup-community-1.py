"""Install pinned Community-1 files through public sources; safe to resume verified files."""

import hashlib
import json
import os
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def install(root=ROOT / ".models/community-1"):
    lock = json.loads((ROOT / "Resources/community-1.lock.json").read_text())
    root.mkdir(parents=True, exist_ok=True)
    for item in lock["files"]:
        path = root / item["path"]
        if (
            path.is_file()
            and not path.is_symlink()
            and hashlib.sha256(path.read_bytes()).hexdigest() == item["sha256"]
        ):
            continue
        if urllib.parse.urlparse(item["url"]).hostname != "huggingface.co":
            raise ValueError("Model URL must use Hugging Face")
        path.parent.mkdir(parents=True, exist_ok=True)
        with urllib.request.urlopen(item["url"], timeout=120) as response:
            data = response.read(item["bytes"] + 1)
        if (
            len(data) != item["bytes"]
            or hashlib.sha256(data).hexdigest() != item["sha256"]
        ):
            raise ValueError("Model verification failed: " + item["path"])
        staging = path.with_name(path.name + ".download")
        staging.write_bytes(data)
        staging.chmod(0o600)
        os.replace(staging, path)
    print("Community-1 installed:", root)


if __name__ == "__main__":
    install()
