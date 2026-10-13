"""Download large-v3 weights; --turbo selects Turbo Q5, --turbo-fp16 selects Turbo FP16."""

import argparse
import hashlib
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODELS = {
    item["id"]: item
    for item in json.loads((ROOT / "Resources/models.json").read_text())["artifacts"]
}


def digest(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    selection = parser.add_mutually_exclusive_group()
    selection.add_argument(
        "--turbo",
        action="store_true",
        help="Install Turbo Q5 instead of full large-v3",
    )
    selection.add_argument(
        "--turbo-fp16",
        action="store_true",
        help="Install unquantized Turbo FP16 instead of full large-v3",
    )
    args = parser.parse_args()
    model = (
        "turbo-q5" if args.turbo else "turbo-fp16" if args.turbo_fp16 else "large-v3"
    )
    artifact = MODELS[model]
    expected = artifact["downloadSHA256"]
    filename = artifact["filename"]
    url = artifact["url"]
    destination = ROOT / ".models" / filename
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        if digest(destination) != expected:
            raise RuntimeError(f"Existing {model} model has an unexpected SHA-256")
        print(f"Verified existing {model} model")
        return
    partial = destination.with_suffix(".bin.part")
    # Keep an incomplete download for the next explicit invocation to resume.
    subprocess.run(
        [
            "curl",
            "--fail",
            "--location",
            "--retry",
            "3",
            "--continue-at",
            "-",
            "--output",
            str(partial),
            url,
        ],
        check=True,
    )
    if digest(partial) != expected:
        raise RuntimeError("SHA-256 mismatch; remove the partial download and retry")
    partial.replace(destination)
    print(f"Verified {model}: {destination}")


if __name__ == "__main__":
    main()
