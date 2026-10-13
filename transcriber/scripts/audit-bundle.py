"""Reject app bundles which still depend on the developer's environment."""

import argparse
import importlib.util
import re
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "bundle_runtime", Path(__file__).with_name("bundle-runtime.py")
)
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)


def version(value):
    parts = tuple(int(part) for part in value.split("."))
    return parts + (0,) * (3 - len(parts))


def audit_bundle(app: Path, minimum_macos: str = "26.0") -> list[str]:
    app = app.resolve()
    errors = []
    for helper in ("transcriber-worker", "transcriber-diarizer"):
        path = app / "Contents/Helpers" / helper
        if not path.is_file() or not runtime.is_macho(path):
            errors.append(f"Missing native helper: {helper}")
    if not (app / "Contents/Resources/community-1.lock.json").is_file():
        errors.append("Missing Community-1 model manifest")
    images = []
    for path in app.rglob("*"):
        if path.is_symlink():
            if not path.resolve().is_relative_to(app):
                errors.append(f"Escaping symlink: {path.relative_to(app)}")
            continue
        if (
            "sherpa" in path.name.lower()
            and path.suffix == ".dylib"
        ):
            errors.append(f"Legacy diarization runtime: {path.name}")
        if path.is_file() and runtime.is_macho(path):
            images.append(path)
    if not images:
        errors.append("No Mach-O executables found")
    for image in images:
        architectures = runtime.run("lipo", "-archs", image).split()
        if "arm64" not in architectures:
            errors.append(f"Missing arm64: {image.name}")
        commands = runtime.run("otool", "-l", image)
        floors = re.findall(r"\bminos (\d+(?:\.\d+)*)", commands)
        floors += re.findall(
            r"cmd LC_VERSION_MIN_MACOSX\n\s*cmdsize \d+\n\s*version (\S+)", commands
        )
        if not floors or any(
            version(floor) > version(minimum_macos) for floor in floors
        ):
            errors.append(f"Unsupported minimum OS: {image.name}: {floors}")
        for rpath in runtime.rpaths(image):
            if rpath.startswith("/") and not rpath.startswith(runtime.SYSTEM):
                errors.append(f"External rpath: {image.name}: {rpath}")
        own = runtime.install_id(image)
        for dependency in runtime.dependencies(image):
            if dependency == own or dependency.startswith(runtime.SYSTEM):
                continue
            if dependency.startswith("/"):
                errors.append(f"External dependency: {image.name}: {dependency}")
                continue
            try:
                resolved = runtime.resolve(
                    dependency, image, app / "Contents/MacOS/Transcriber"
                )
                if not resolved.is_relative_to(app):
                    errors.append(
                        f"External resolved dependency: {image.name}: {dependency}"
                    )
            except RuntimeError as error:
                errors.append(str(error))
    backends = app / "Contents/Frameworks/ggml"
    for kind in ["cpu", "metal"]:
        if not list(backends.glob(f"libggml-{kind}*.so")):
            errors.append(f"Missing {kind} backend")
    return errors


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    args = parser.parse_args()
    problems = audit_bundle(args.app)
    for problem in problems:
        print(problem)
    if not problems:
        print("Bundle audit passed: arm64, macOS 26, internal runtime dependencies")
    raise SystemExit(bool(problems))
