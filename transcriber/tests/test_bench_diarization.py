import importlib.util
import unittest
from pathlib import Path

try:
    from pyannote.core import Annotation, Segment
    from pyannote.metrics.diarization import DiarizationErrorRate  # noqa: F401

    AVAILABLE = True
except ImportError:
    AVAILABLE = False


@unittest.skipUnless(
    AVAILABLE, "development-only pyannote.metrics environment required"
)
class ScoringTests(unittest.TestCase):
    def test_permutation_and_split(self):
        spec = importlib.util.spec_from_file_location(
            "bench",
            Path(__file__).resolve().parents[1] / "scripts/bench-diarization.py",
        )
        bench = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(bench)
        reference = Annotation(uri="test")
        reference[Segment(0, 4)] = "alice"
        reference[Segment(4, 8)] = "bob"
        turns = [
            {"startMS": 0, "endMS": 4000, "speaker": 9},
            {"startMS": 4000, "endMS": 8000, "speaker": 3},
        ]
        self.assertEqual(bench.score(reference, turns)["der"], 0)
        turns = [
            {"startMS": 0, "endMS": 2000, "speaker": 0},
            {"startMS": 2000, "endMS": 4000, "speaker": 1},
            turns[1],
        ]
        result = bench.score(reference, turns)
        self.assertEqual(result["splitSpeakers"], 1)
        self.assertGreater(result["der"], 0)
        self.assertGreater(bench.score(reference, [])["der"], 0)
