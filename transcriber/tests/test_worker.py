"""Native integration checks; run after building the local worker."""

import json
import random
import shutil
import struct
import subprocess
import tempfile
import unittest
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKER = ROOT / "build/transcriber-worker"
VAD = ROOT / ".deps/downloads/ggml-silero-v6.2.0.bin"


class WorkerTests(unittest.TestCase):
    @unittest.skipUnless(
        (ROOT / ".models/ggml-large-v3-turbo-q5_0.bin").exists(),
        "local ASR model required",
    )
    def test_context_over_whisper_budget_is_rejected_without_truncation(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / "audio.wav"
            with wave.open(str(source), "wb") as audio:
                audio.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
                audio.writeframes(struct.pack("<h", 100) * 16000)
            context = Path(folder) / "context.txt"
            context.write_text(" x" * 400)
            output = Path(folder) / "transcript.json.preview.json"
            result = subprocess.run(
                [
                    str(WORKER),
                    "--prepare",
                    str(source),
                    str(ROOT / ".models/ggml-large-v3-turbo-q5_0.bin"),
                    str(output.parent),
                    "--context-file",
                    str(context),
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 3, result.stderr)
            self.assertIn("слишком длинный для Whisper", result.stderr)
            self.assertFalse(output.exists())

    def test_invalid_meeting_context_is_rejected_before_media_processing(self):
        with tempfile.TemporaryDirectory() as folder:
            context = Path(folder) / "context.txt"
            output = Path(folder) / "transcript.json.preview.json"
            for data in (b"x" * 4097, b"invalid\x00text", b"\xff"):
                with self.subTest(data_length=len(data)):
                    context.write_bytes(data)
                    result = subprocess.run(
                        [
                            str(WORKER),
                            "--prepare",
                            "missing.wav",
                            "unused",
                            str(output.parent),
                            "--context-file",
                            str(context),
                        ],
                        capture_output=True,
                        text=True,
                        check=False,
                    )
                    self.assertEqual(result.returncode, 3, result.stderr)
                    self.assertEqual(result.stdout, "")
                    self.assertFalse(output.exists())

    def test_dictionary_and_meeting_context_are_mutually_exclusive(self):
        result = subprocess.run(
            [
                str(WORKER),
                "--prepare",
                "missing.wav",
                "unused",
                "/tmp",
                "dictionary.txt",
                "--context-file",
                "context.txt",
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 1)
        self.assertIn("либо словарь, либо контекст", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_removed_denoise_option_is_rejected_before_processing(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / "audio.wav"
            with wave.open(str(source), "wb") as audio:
                audio.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
                audio.writeframes(struct.pack("<h", 100) * 16000)
            output = Path(folder) / "transcript.json.preview.json"
            result = subprocess.run(
                [
                    str(WORKER),
                    "--prepare",
                    str(source),
                    "unused",
                    str(output.parent),
                    "--denoise-model",
                    str(Path(folder) / "missing-model"),
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 1)
            self.assertIn("Неверные аргументы worker", result.stderr)
            self.assertEqual(result.stdout, "")
            self.assertFalse(output.exists())
            self.assertFalse(Path(str(output) + ".preview.json").exists())

    @unittest.skipUnless(VAD.exists(), "local VAD model required")
    def test_corrupt_vad_model_falls_back_without_aborting(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / "audio.wav"
            with wave.open(str(source), "wb") as audio:
                audio.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
                audio.writeframes(struct.pack("<h", 8) * 16000 * 5)
            corrupt = Path(folder) / "corrupt-vad.bin"
            data = bytearray(VAD.read_bytes())
            struct.pack_into("<i", data, 30, 0)
            corrupt.write_bytes(data)
            output = Path(folder) / "transcript.json.preview.json"
            result = subprocess.run(
                [
                    str(WORKER),
                    "--prepare",
                    str(source),
                    "missing-asr",
                    str(output.parent),
                    "--vad-model",
                    str(corrupt),
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 1)
            self.assertIn("VAD unavailable", result.stderr)
            self.assertIn("Не удалось загрузить модель распознавания", result.stderr)
            self.assertFalse(output.exists())

    @unittest.skipUnless(VAD.exists(), "local models required")
    def test_conservative_vad_skips_quiet_window_but_missing_vad_keeps_asr(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / "quiet.wav"
            rng = random.Random(42)
            noise = b"".join(
                struct.pack("<h", rng.randint(-8, 8)) for _ in range(25 * 16000)
            )
            with wave.open(str(source), "wb") as audio:
                audio.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
                audio.writeframes(noise)
            output = Path(folder) / "transcript.json.preview.json"
            command = [
                str(WORKER),
                "--prepare",
                str(source),
                "missing-asr",
            ]
            result = subprocess.run(
                command + [folder, "--vad-model", str(VAD)],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("vad: skipped=1 total=1", result.stderr)
            document = json.loads(output.read_text())
            self.assertEqual(document["segments"], [])
            self.assertEqual(document["durationMS"], 25000)
            fallback_directory = Path(folder) / "fallback"
            fallback_directory.mkdir()
            fallback = fallback_directory / "transcript.json.preview.json"
            result = subprocess.run(
                command
                + [
                    str(fallback_directory),
                    "--vad-model",
                    str(Path(folder) / "missing-vad"),
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("VAD", result.stderr)
            self.assertIn("Не удалось загрузить модель распознавания", result.stderr)
            self.assertFalse(fallback.exists())

    @unittest.skipUnless(
        shutil.which("ffmpeg"), "ffmpeg needed for delayed media fixture"
    )
    def test_preserves_delayed_audio_timeline(self):
        with tempfile.TemporaryDirectory() as folder:
            wave_path = Path(folder) / "silence.wav"
            with wave.open(str(wave_path), "wb") as audio:
                audio.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
                audio.writeframes(b"\x00\x00" * 16000 * 2)
            source = Path(folder) / "delayed.m4a"
            subprocess.run(
                [
                    "ffmpeg",
                    "-v",
                    "error",
                    "-itsoffset",
                    "2",
                    "-i",
                    str(wave_path),
                    "-c:a",
                    "aac",
                    "-copyts",
                    str(source),
                ],
                check=True,
            )
            output = Path(folder) / "transcript.json.preview.json"
            result = subprocess.run(
                [str(WORKER), "--prepare", str(source), "unused", str(output.parent)],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            document = json.loads(output.read_text())
            self.assertAlmostEqual(document["durationMS"], 4000, delta=100)

    def test_rejects_missing_arguments_without_a_success_artifact(self):
        result = subprocess.run(
            [str(WORKER)], capture_output=True, text=True, check=False
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("usage", result.stderr.lower())

    def test_rejects_bad_media_and_does_not_publish_a_result(self):
        with tempfile.TemporaryDirectory(prefix="тест записи ") as folder:
            source = Path(folder) / "bad media.mp4"
            source.write_text("not media")
            output = Path(folder) / "transcript.json.preview.json"
            result = subprocess.run(
                [
                    str(WORKER),
                    "--prepare",
                    str(source),
                    "missing-model",
                    str(output.parent),
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(output.exists())

    def test_silence_is_a_successful_empty_transcript(self):
        with tempfile.TemporaryDirectory(prefix="transcriber silence ") as folder:
            source = Path(folder) / "тишина.wav"
            with wave.open(str(source), "wb") as audio:
                audio.setparams((1, 2, 16000, 0, "NONE", "not compressed"))
                audio.writeframes(b"\x00\x00" * 16000 * 2)
            output = Path(folder) / "transcript.json.preview.json"
            context = Path(folder) / "context.txt"
            context.write_text("Анна, TestFlight, C#, задача #123", encoding="utf-8")
            result = subprocess.run(
                [
                    str(WORKER),
                    "--prepare",
                    str(source),
                    "unused-model",
                    str(output.parent),
                    "--context-file",
                    str(context),
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            document = json.loads(output.read_text())
            self.assertEqual(document["schemaVersion"], 1)
            self.assertEqual(document["segments"], [])
            self.assertEqual(document["durationMS"], 2000)


if __name__ == "__main__":
    unittest.main()
