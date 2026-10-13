import os
import subprocess
import unittest
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"


class ReleaseScriptTests(unittest.TestCase):
    def test_missing_developer_identity_fails_before_build(self):
        environment = dict(os.environ)
        environment.pop("TRANSCRIBER_SIGN_IDENTITY", None)
        result = subprocess.run(
            ["bash", str(SCRIPTS / "build-dmg.sh"), "--mode", "developer-id"],
            env=environment,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("TRANSCRIBER_SIGN_IDENTITY", result.stderr)
        self.assertNotIn("clang++", result.stdout)

    def test_adhoc_cannot_request_notarization(self):
        result = subprocess.run(
            ["bash", str(SCRIPTS / "build-dmg.sh"), "--mode", "adhoc", "--notarize"],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("developer-id", result.stderr)


if __name__ == "__main__":
    unittest.main()
