"""Sequential local model comparison; retain timed progress, diagnostics and results."""

import argparse
import json
import os
import re
import signal
import subprocess
import time
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--profiles", nargs="+", default=["large-v3", "quality"])
    parser.add_argument(
        "--cache-dir", type=Path, help="Reuse speaker turns across benchmark runs"
    )
    parser.add_argument(
        "--no-vad", action="store_true", help="Disable conservative VAD for comparison"
    )
    args = parser.parse_args()
    os.umask(0o077)
    root = Path(__file__).resolve().parents[1]
    resources = root / "build/Transcriber.app/Contents/Resources"
    config = json.loads((resources / "runtime.json").read_text())
    profiles = {profile["id"]: profile for profile in config["profiles"]}
    for name in args.profiles:
        if name not in profiles or not Path(profiles[name]["path"]).is_file():
            parser.error(f"Profile is not installed: {name}")
    if not args.source.is_file():
        parser.error("Source does not exist")
    args.output.mkdir(parents=True, exist_ok=False)
    summaries = []
    for name in args.profiles:
        folder = args.output / name
        folder.mkdir()
        prepare = [
            str(resources / "transcriber-worker"),
            "--prepare",
            str(args.source.resolve()),
            profiles[name]["path"],
            str(folder.resolve()),
        ]
        if config.get("vad") and not args.no_vad:
            prepare.extend(["--vad-model", config["vad"]])
        commands = [
            prepare,
            [
                str(resources / "transcriber-diarizer"),
                "--attempt-dir",
                str(folder.resolve()),
                "--model-dir",
                config["diarizationModelDirectory"],
                "--model-manifest",
                config["diarizationManifest"],
                "--cache-dir",
                str((args.cache_dir or args.output / "cache").resolve()),
            ],
            [
                str(resources / "transcriber-worker"),
                "--finalize",
                str(folder.resolve()),
            ],
        ]
        started = time.monotonic()
        previous_stage = None
        previous_time = 0.0
        last_report = None
        stage_seconds = {}
        print(f"START {name}", flush=True)
        with (
            (folder / "worker.log").open("w") as errors,
            (folder / "progress.ndjson").open("w") as progress,
        ):
            for command in commands:
                child = subprocess.Popen(
                    ["/usr/bin/time", "-l", "-p", *command],
                    stdout=subprocess.PIPE,
                    stderr=errors,
                    text=True,
                    start_new_session=True,
                )
                try:
                    for line in child.stdout:
                        event = json.loads(line)
                        elapsed = time.monotonic() - started
                        event["elapsedSeconds"] = round(elapsed, 3)
                        progress.write(json.dumps(event) + "\n")
                        progress.flush()
                        stage = event["stage"]
                        if stage != previous_stage:
                            if previous_stage is not None:
                                stage_seconds[previous_stage] = round(
                                    elapsed - previous_time, 3
                                )
                            previous_stage, previous_time = stage, elapsed
                        report = (stage, int(event["progress"] * 10))
                        if report != last_report:
                            print(
                                f"{name}: {stage} {event['progress']:.0%}, elapsed {elapsed:.1f}s",
                                flush=True,
                            )
                            last_report = report
                    code = child.wait()
                finally:
                    if child.poll() is None:
                        os.killpg(child.pid, signal.SIGTERM)
                        try:
                            child.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            os.killpg(child.pid, signal.SIGKILL)
                            child.wait()
                    child.stdout.close()
                if code:
                    break
        if code:
            raise RuntimeError(f"{name} exited {code}; see {folder / 'worker.log'}")
        log = (folder / "worker.log").read_text()
        summary = {
            "profile": name,
            "model": Path(profiles[name]["path"]).name,
            "elapsedSeconds": round(time.monotonic() - started, 3),
            "stageSeconds": stage_seconds,
        }
        for field, label in [
            ("maxRSSBytes", "maximum resident set size"),
            ("peakFootprintBytes", "peak memory footprint"),
        ]:
            matches = re.findall(r"(\d+)\s+" + label, log)
            if matches:
                summary[field] = max(map(int, matches))
        summaries.append(summary)
        (args.output / "summary.json").write_text(json.dumps(summaries, indent=2))
        print(json.dumps(summary), flush=True)


if __name__ == "__main__":

    def terminate(_signal, _frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, terminate)
    main()
