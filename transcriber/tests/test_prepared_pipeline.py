"""Actual native stage boundaries; no ASR model needed for silence/finalization."""

import json
import struct
import subprocess
import tempfile
import unittest
import wave
from pathlib import Path

WORKER = Path(__file__).resolve().parents[1] / "build/transcriber-worker"


class PreparedPipelineTests(unittest.TestCase):
    def prepare(self, root):
        source = root / "source.wav"
        with wave.open(str(source), "wb") as audio:
            audio.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
            audio.writeframes(bytes(32000))
        return subprocess.run(
            [str(WORKER), "--prepare", str(source), "unused", str(root)],
            check=False,
            capture_output=True,
            text=True,
        )

    def test_prepare_silence_writes_pcm_and_empty_words(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            result = self.prepare(root)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((root / "audio.f32").stat().st_size, 64000)
            self.assertEqual(
                json.loads((root / "prepared.json").read_text())["durationMS"], 1000
            )
            self.assertEqual(json.loads((root / "words.json").read_text()), [])
            self.assertTrue((root / "transcript.json.preview.json").exists())
            self.assertFalse((root / "transcript.json").exists())

    def fixture(self, root):
        manifest = {
            "schemaVersion": 1,
            "sampleRate": 16000,
            "sampleCount": 16000,
            "durationMS": 1000,
            "pcmFormat": "f32le-mono",
            "decodeVersion": 1,
            "sourceSHA256": "a" * 64,
            "pcmFile": "audio.f32",
            "wordsFile": "words.json",
            "asrModel": "test",
        }
        (root / "prepared.json").write_text(json.dumps(manifest))
        (root / "audio.f32").write_bytes(bytes(64000))
        (root / "words.json").write_text(
            json.dumps(
                [
                    {"startMS": 0, "endMS": 400, "text": "Привет"},
                    {"startMS": 500, "endMS": 1000, "text": "Ответ"},
                ]
            )
        )
        (root / "turns.json").write_text(
            json.dumps(
                {
                    "schemaVersion": 1,
                    "durationMS": 1000,
                    "provenance": {
                        "engine": "community-1-fluidaudio",
                        "sdkRevision": "a" * 40,
                        "modelRevision": "b" * 40,
                        "modelManifestSHA256": "c" * 64,
                        "configurationSHA256": "d" * 64,
                        "computeUnits": "all",
                    },
                    "turns": [
                        {"startMS": 0, "endMS": 400, "speaker": 0},
                        {"startMS": 500, "endMS": 1000, "speaker": 1},
                    ],
                }
            )
        )
        return manifest

    def finalize(self, root):
        return subprocess.run(
            [str(WORKER), "--finalize", str(root)],
            check=False,
            capture_output=True,
            text=True,
        )

    def test_finalize_uses_original_word_boundaries(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            self.fixture(root)
            result = self.finalize(root)
            self.assertEqual(result.returncode, 0, result.stderr)
            doc = json.loads((root / "transcript.json").read_text())
            self.assertEqual([r["speaker"] for r in doc["segments"]], [0, 1])
            self.assertEqual([r["startMS"] for r in doc["segments"]], [0, 500])
            self.assertEqual(doc["diarization"]["engine"], "community-1-fluidaudio")

    def test_alignment_failure_preserves_original_words(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            self.fixture(root)
            before = (root / "words.json").read_bytes()
            result = subprocess.run(
                [str(WORKER), "--align", str(root), str(root / "missing.onnx")],
                capture_output=True, text=True, check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("alignment fallback:", result.stderr)
            self.assertEqual((root / "words.json").read_bytes(), before)
            self.assertEqual(self.finalize(root).returncode, 0)

    def test_invalid_prepared_inputs_are_rejected(self):
        for kind in (
            "nan",
            "short",
            "extra",
            "path",
            "schema",
            "rate",
            "duration",
            "words",
            "turns",
        ):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                manifest = self.fixture(root)
                if kind == "nan":
                    (root / "audio.f32").write_bytes(
                        struct.pack("<f", float("nan")) + bytes(63996)
                    )
                if kind == "short":
                    (root / "audio.f32").write_bytes(bytes(4))
                if kind == "extra":
                    (root / "audio.f32").write_bytes(bytes(64004))
                if kind == "path":
                    manifest["pcmFile"] = "../outside"
                if kind == "schema":
                    manifest["schemaVersion"] = 2
                if kind == "rate":
                    manifest["sampleRate"] = 48000
                if kind == "duration":
                    manifest["sampleCount"] = 230400001
                if kind == "words":
                    (root / "words.json").write_text(
                        '[{"startMS":500,"endMS":100,"text":"bad"}]'
                    )
                if kind == "turns":
                    path = root / "turns.json"
                    doc = json.loads(path.read_text())
                    doc["turns"][0]["speaker"] = -1
                    path.write_text(json.dumps(doc))
                (root / "prepared.json").write_text(json.dumps(manifest))
                self.assertNotEqual(self.finalize(root).returncode, 0)
                self.assertFalse((root / "transcript.json").exists())


if __name__ == "__main__":
    unittest.main()
