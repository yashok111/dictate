"""Score Community-1 turns against RTTM. Install benchmark-requirements.txt first."""

import argparse
import json
from pathlib import Path


def score(reference, turns, minimum_overlap=1.0):
    from pyannote.core import Annotation, Segment
    from pyannote.metrics.diarization import DiarizationErrorRate

    hypothesis = Annotation(uri=reference.uri)
    for index, turn in enumerate(turns):
        start, end = turn["startMS"] / 1000, turn["endMS"] / 1000
        if start < 0 or end <= start or turn["speaker"] < 0:
            raise ValueError("Invalid system turn")
        hypothesis[Segment(start, end), index] = str(turn["speaker"])
    metric = DiarizationErrorRate(collar=0, skip_overlap=False)
    der = metric(reference, hypothesis)
    overlaps = {}
    for segment, _, speaker in reference.itertracks(yield_label=True):
        for other, _, label in hypothesis.itertracks(yield_label=True):
            value = max(
                0, min(segment.end, other.end) - max(segment.start, other.start)
            )
            overlaps[speaker, label] = overlaps.get((speaker, label), 0) + value
    by_reference, by_system = {}, {}
    for (speaker, label), seconds in overlaps.items():
        if seconds >= minimum_overlap:
            by_reference.setdefault(speaker, set()).add(label)
            by_system.setdefault(label, set()).add(speaker)
    return {
        "der": der,
        "referenceSpeakers": len(reference.labels()),
        "systemSpeakers": len(hypothesis.labels()),
        "splitSpeakers": sum(len(labels) > 1 for labels in by_reference.values()),
        "mergedSpeakers": sum(len(labels) > 1 for labels in by_system.values()),
        "diagnosticMinimumOverlapSeconds": minimum_overlap,
    }


def main():
    from pyannote.database.util import load_rttm

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reference", type=Path)
    parser.add_argument("turns", type=Path)
    parser.add_argument(
        "--recording", help="RTTM URI when reference has several recordings"
    )
    args = parser.parse_args()
    references = load_rttm(args.reference)
    uri = args.recording
    if uri is None:
        if len(references) != 1:
            parser.error("Specify --recording for a multi-recording RTTM")
        uri = next(iter(references))
    result = score(references[uri], json.loads(args.turns.read_text())["turns"])
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
