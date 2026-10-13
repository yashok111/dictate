"""Behavioral tests for relocatable Mach-O packaging."""

import importlib.util
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"


def module(name):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / f"{name}.py")
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


class BundleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="пакет with spaces ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = self.root / "Test.app"
        (self.app / "Contents/MacOS").mkdir(parents=True)
        (self.app / "Contents/Frameworks/ggml").mkdir(parents=True)
        (self.app / "Contents/Helpers").mkdir(parents=True)
        (self.app / "Contents/Resources").mkdir(parents=True)
        (self.app / "Contents/Resources/community-1.lock.json").write_text("{}")
        self.lib = self.root / "libfixture.dylib"
        source = self.root / "lib.c"
        source.write_text("int answer(void) { return 42; }")
        subprocess.run(
            [
                "clang",
                "-dynamiclib",
                "-mmacosx-version-min=26.0",
                str(source),
                "-Wl,-install_name," + str(self.lib),
                "-o",
                str(self.lib),
            ],
            check=True,
            capture_output=True,
        )
        main = self.root / "main.c"
        main.write_text(
            "int answer(void); int main(void) { return answer() == 42 ? 0 : 1; }"
        )
        self.exe = self.app / "Contents/MacOS/Transcriber"
        subprocess.run(
            [
                "clang",
                "-mmacosx-version-min=26.0",
                str(main),
                str(self.lib),
                "-o",
                str(self.exe),
            ],
            check=True,
            capture_output=True,
        )

    def test_external_dependency_rejected_and_relocated_program_runs(self):
        audit = module("audit-bundle")
        before = audit.audit_bundle(self.app)
        self.assertTrue(any("external" in error.lower() for error in before), before)
        bundler = module("bundle-runtime")
        backend = self.root / "backends"
        backend.mkdir()
        # Real dynamic module fixture, not text with a .so suffix.
        for name in ["libggml-cpu.so", "libggml-metal.so"]:
            (backend / name).write_bytes(self.lib.read_bytes())
        worker = self.root / "worker"
        shutil.copy2(self.exe, worker)
        shutil.copy2(worker, self.app / "Contents/Helpers/transcriber-diarizer")
        bundler.bundle_runtime(self.app, worker, backend)
        self.lib.unlink()
        self.assertEqual(audit.audit_bundle(self.app), [])
        for image in self.app.rglob("*"):
            if image.is_file() and bundler.is_macho(image):
                subprocess.run(
                    ["codesign", "--force", "--sign", "-", str(image)],
                    check=True,
                    capture_output=True,
                )
        result = subprocess.run([str(self.exe)], capture_output=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_escaping_symlink_and_missing_backend_rejected(self):
        audit = module("audit-bundle")
        (self.app / "Contents/Frameworks/escape").symlink_to(self.lib)
        errors = audit.audit_bundle(self.app)
        self.assertTrue(any("symlink" in e.lower() for e in errors), errors)
        self.assertTrue(any("backend" in e.lower() for e in errors), errors)

    def test_missing_diarizer_is_rejected(self):
        errors = module("audit-bundle").audit_bundle(self.app)
        self.assertTrue(any("transcriber-diarizer" in e for e in errors), errors)

    def test_floor_parser_rejects_newer_binary(self):
        audit = module("audit-bundle")
        self.assertTrue(
            any(
                "minimum" in e.lower()
                for e in audit.audit_bundle(self.app, minimum_macos="25.0")
            )
        )


if __name__ == "__main__":
    unittest.main()
