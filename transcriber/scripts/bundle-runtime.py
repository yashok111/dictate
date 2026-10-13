"""Copy and relocate the complete non-system Mach-O runtime into an app."""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
from pathlib import Path

SYSTEM = ("/System/Library/", "/usr/lib/")
MAGIC = {
    b"\xcf\xfa\xed\xfe",
    b"\xce\xfa\xed\xfe",
    b"\xca\xfe\xba\xbe",
    b"\xca\xfe\xba\xbf",
}


def run(*args):
    return subprocess.check_output([str(arg) for arg in args], text=True)


def is_macho(path):
    with path.open("rb") as source:
        return source.read(4) in MAGIC


def dependencies(path):
    return [
        line.strip().split(" (compatibility version")[0]
        for line in run("otool", "-L", path).splitlines()[1:]
        if "compatibility version" in line
    ]


def install_id(path):
    lines = run("otool", "-D", path).splitlines()
    return lines[1].strip() if len(lines) > 1 else None


def rpaths(path):
    return re.findall(
        r"cmd LC_RPATH\n\s*cmdsize \d+\n\s*path (.*?) \(offset",
        run("otool", "-l", path),
    )


def expand(value, source, executable):
    return value.replace("@loader_path", str(source.parent)).replace(
        "@executable_path", str(executable.parent)
    )


def resolve(dependency, source, executable):
    if dependency.startswith("@rpath/"):
        name = dependency[len("@rpath/") :]
        candidates = [
            Path(expand(item, source, executable)) / name for item in rpaths(source)
        ]
        candidates += [
            source.parent / name,
            executable.parent.parent / "Frameworks" / name,
        ]
    else:
        candidates = [Path(expand(dependency, source, executable))]
    for candidate in candidates:
        if candidate.is_file():
            return candidate.resolve()
    raise RuntimeError(f"Unresolved dependency {dependency} in {source}")


def digest(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def bundle_runtime(app: Path, worker: Path, backend_dir: Path) -> None:
    app = app.resolve()
    frameworks = app / "Contents/Frameworks"
    backends = frameworks / "ggml"
    helpers = app / "Contents/Helpers"
    for directory in (frameworks, backends, helpers):
        directory.mkdir(parents=True, exist_ok=True)
    helper = helpers / "transcriber-worker"
    shutil.copy2(worker.resolve(), helper)
    images = {
        path.resolve(): path
        for path in app.rglob("*")
        if path.is_file() and is_macho(path)
    }
    # Preserve original helper context while resolving developer rpaths.
    images.pop(helper.resolve(), None)
    images[worker.resolve()] = helper
    for source in backend_dir.iterdir():
        if source.is_file() and is_macho(source):
            destination = backends / source.name
            shutil.copy2(source.resolve(), destination)
            images[source.resolve()] = destination
        elif source.is_file() and source.suffix in {".metal", ".metallib"}:
            shutil.copy2(source, backends / source.name)
    executable = app / "Contents/MacOS/Transcriber"
    edges = {}
    destinations = {str(destination): source for source, destination in images.items()}
    pending = list(images)
    manifest = []
    while pending:
        source = pending.pop()
        own_id = install_id(source)
        edges[source] = []
        manifest.append(
            {
                "file": str(images[source].relative_to(app)),
                "sha256BeforeRelocation": digest(source),
            }
        )
        for dependency in dependencies(source):
            if dependency == own_id or dependency.startswith(SYSTEM):
                continue
            resolved = resolve(dependency, source, executable)
            if resolved not in images:
                destination = frameworks / resolved.name
                previous = destinations.get(str(destination))
                if (
                    previous
                    and previous != resolved
                    and digest(previous) != digest(resolved)
                ):
                    raise RuntimeError(
                        f"Dependency basename collision: {resolved.name}"
                    )
                if previous:
                    images[resolved] = destination
                else:
                    shutil.copy2(resolved, destination)
                    images[resolved] = destination
                    destinations[str(destination)] = resolved
                    pending.append(resolved)
            edges[source].append((dependency, resolved))
    for source, links in edges.items():
        destination = images[source]
        args = ["install_name_tool"]
        for old, dependency in links:
            relative = os.path.relpath(images[dependency], destination.parent)
            args += ["-change", old, "@loader_path/" + relative]
        for rpath in set(rpaths(destination)):
            args += ["-delete_rpath", rpath]
        if install_id(destination):
            args += ["-id", "@rpath/" + str(destination.relative_to(frameworks))]
        if len(args) > 1:
            subprocess.run([*args, str(destination)], check=True, capture_output=True)
    resources = app / "Contents/Resources"
    resources.mkdir(exist_ok=True)
    (resources / "runtime-build.json").write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("worker", type=Path)
    parser.add_argument("backend_dir", type=Path)
    args = parser.parse_args()
    bundle_runtime(args.app, args.worker, args.backend_dir)
