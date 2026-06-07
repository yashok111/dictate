#!/usr/bin/env python3
"""WER bench harness for the dictate initial_prompt (lexical-bias dictionary).

Measures the word error rate (WER) of the local whisper.cpp transcription WITHOUT vs WITH
the user dictionary, over a folder of Russian reference clips, so you can quantify the
accuracy the dictionary buys on YOUR vocabulary (names, tech terms, English-in-Russian) —
this is the "Замер" the feature needs. It also watches for the turbo prompt-sensitivity
loop/hallucination (project gotcha #11): if the biased hypothesis balloons versus the
reference, the clip is flagged ⚠.

Layout — each clip is a 16 kHz mono WAV `foo.wav` paired with a UTF-8 plaintext reference
`foo.ref.txt` (or `foo.txt`) holding the correct transcript:

    bench/clips/
        take01.wav   take01.ref.txt
        take02.wav   take02.ref.txt

The harness transcribes each clip twice via `dictate --file <wav> --once` (single-pass over
the whole clip — deterministic A/B, and `--once` is NOT length-capped, unlike streaming
`--file`; gotcha #18):
    • baseline — env WHISPER_PROMPT=0            (dictionary OFF)
    • biased   — env WHISPER_DICT=<dict>         (dictionary ON)
then prints per-clip and aggregate WER plus the delta.

NOTE (gotcha #19): run this ON THE MAC with the model installed — it drives the real
`dictate` binary. The script itself is plain-stdlib Python 3 (no third-party deps), so
`--help` and the WER math work anywhere.

Usage:
    python3 scripts/bench-wer.py --clips bench/clips
    python3 scripts/bench-wer.py --clips bench/clips --dict ~/.config/whisper/dictionary.txt
    python3 scripts/bench-wer.py --clips bench/clips --bin ./dictate --verbose
"""
import argparse
import os
import re
import subprocess
import sys

# Word = a run of Cyrillic / Latin letters or digits; everything else (punctuation, spaces)
# is a separator. Case-folded so scoring isn't thrown by capitalization.
_WORD_RE = re.compile(r"[0-9a-zа-яё]+", re.UNICODE)


def normalize(text):
    """Lower-case and tokenize into comparable words (drops punctuation/whitespace)."""
    return _WORD_RE.findall(text.lower().replace("ё", "е"))


def align_counts(ref, hyp):
    """Levenshtein over word lists → (substitutions, deletions, insertions, hits)."""
    n, m = len(ref), len(hyp)
    dp = [[0] * (m + 1) for _ in range(n + 1)]
    for i in range(n + 1):
        dp[i][0] = i
    for j in range(m + 1):
        dp[0][j] = j
    for i in range(1, n + 1):
        ri = ref[i - 1]
        for j in range(1, m + 1):
            if ri == hyp[j - 1]:
                dp[i][j] = dp[i - 1][j - 1]
            else:
                dp[i][j] = 1 + min(dp[i - 1][j - 1], dp[i - 1][j], dp[i][j - 1])
    # backtrace to split the edit distance into S / D / I (and count hits H)
    i, j = n, m
    S = D = I = H = 0
    while i > 0 or j > 0:
        if i > 0 and j > 0 and ref[i - 1] == hyp[j - 1] and dp[i][j] == dp[i - 1][j - 1]:
            H += 1; i -= 1; j -= 1
        elif i > 0 and j > 0 and dp[i][j] == dp[i - 1][j - 1] + 1:
            S += 1; i -= 1; j -= 1
        elif i > 0 and dp[i][j] == dp[i - 1][j] + 1:
            D += 1; i -= 1
        else:
            I += 1; j -= 1
    return S, D, I, H


def looks_like_loop(ref_n, hyp_words):
    """Heuristic for gotcha #11: a hypothesis far longer than the reference, or one
    dominated by a single repeated token, smells like a turbo prompt-induced loop."""
    h = len(hyp_words)
    if h == 0:
        return False
    if ref_n and h > 2 * ref_n + 5:
        return True
    # any single word making up >60% of a non-trivial hypothesis
    if h >= 8:
        top = max(hyp_words.count(w) for w in set(hyp_words))
        if top > 0.6 * h:
            return True
    return False


def transcribe(binpath, wav, env_overrides, once, timeout):
    """Run the dictate binary on one WAV and return its stdout transcript."""
    env = dict(os.environ)
    env.update(env_overrides)
    args = [binpath, "--file", wav] + (["--once"] if once else [])
    try:
        r = subprocess.run(args, capture_output=True, text=True, env=env, timeout=timeout)
    except subprocess.TimeoutExpired:
        return None, "timeout"
    if r.returncode != 0:
        return None, (r.stderr.strip().splitlines() or ["exit %d" % r.returncode])[-1]
    return r.stdout.strip(), None


def find_clips(clips_dir):
    """Yield (wav_path, ref_text) for every WAV that has a sibling reference file."""
    out = []
    for name in sorted(os.listdir(clips_dir)):
        if not name.lower().endswith(".wav"):
            continue
        stem = os.path.join(clips_dir, name[:-4])
        ref_path = next((p for p in (stem + ".ref.txt", stem + ".txt") if os.path.exists(p)), None)
        if not ref_path:
            print("⚠ skip %s — no .ref.txt / .txt reference" % name, file=sys.stderr)
            continue
        with open(ref_path, encoding="utf-8") as f:
            out.append((os.path.join(clips_dir, name), f.read()))
    return out


def fmt_wer(s, d, i, n):
    return float(s + d + i) / n if n else (0.0 if (s + d + i) == 0 else 1.0)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--clips", required=True, help="folder of <name>.wav + <name>.ref.txt clips")
    ap.add_argument("--bin", default="./dictate", help="path to the dictate binary (default ./dictate)")
    ap.add_argument("--dict", default=None,
                    help="dictionary file for the biased run (default: the binary's own "
                         "~/.config/whisper/dictionary.txt)")
    ap.add_argument("--stream", action="store_true", help="use streaming --file instead of --once")
    ap.add_argument("--timeout", type=int, default=300, help="per-transcription timeout, seconds")
    ap.add_argument("--verbose", action="store_true", help="print every hypothesis")
    args = ap.parse_args()

    if not os.path.isdir(args.clips):
        ap.error("--clips %r is not a directory" % args.clips)
    clips = find_clips(args.clips)
    if not clips:
        ap.error("no clips with references found in %r" % args.clips)

    biased_env = {"WHISPER_DICT": os.path.expanduser(args.dict)} if args.dict else {}
    biased_env.setdefault("WHISPER_PROMPT", "1")  # ensure not disabled by an inherited env
    once = not args.stream

    print("clip                         WER_base   WER_dict      Δ   flag")
    print("-" * 68)
    tot_base = [0, 0, 0, 0]   # S,D,I,N accumulators (micro-average)
    tot_dict = [0, 0, 0, 0]
    for wav, ref_text in clips:
        ref = normalize(ref_text)
        hb, eb = transcribe(args.bin, wav, {"WHISPER_PROMPT": "0"}, once, args.timeout)
        hd, ed = transcribe(args.bin, wav, biased_env, once, args.timeout)
        name = os.path.basename(wav)
        if eb or ed:
            print("%-28s  ERROR: %s" % (name[:28], eb or ed))
            continue
        wb = normalize(hb)
        wd = normalize(hd)
        bS, bD, bI, _ = align_counts(ref, wb)   # baseline (dict off) sub/del/ins
        dS, dD, dI, _ = align_counts(ref, wd)   # dict on
        wer_b = fmt_wer(bS, bD, bI, len(ref))
        wer_d = fmt_wer(dS, dD, dI, len(ref))
        for acc, vals in ((tot_base, (bS, bD, bI)), (tot_dict, (dS, dD, dI))):
            acc[0] += vals[0]; acc[1] += vals[1]; acc[2] += vals[2]; acc[3] += len(ref)
        flag = "⚠loop" if looks_like_loop(len(ref), wd) else ""
        print("%-28s  %7.1f%%  %7.1f%%  %+5.1f   %s"
              % (name[:28], 100 * wer_b, 100 * wer_d, 100 * (wer_d - wer_b), flag))
        if args.verbose:
            print("    ref : %s" % " ".join(ref))
            print("    base: %s" % " ".join(wb))
            print("    dict: %s" % " ".join(wd))
    print("-" * 68)
    agg_b = fmt_wer(*tot_base)
    agg_d = fmt_wer(*tot_dict)
    print("%-28s  %7.1f%%  %7.1f%%  %+5.1f   (micro-avg over %d ref words)"
          % ("ALL", 100 * agg_b, 100 * agg_d, 100 * (agg_d - agg_b), tot_base[3]))
    if tot_base[3]:
        verdict = "dictionary IMPROVED WER" if agg_d < agg_b else (
            "no change" if agg_d == agg_b else "dictionary REGRESSED WER — check ⚠loop flags (gotcha #11)")
        print("→ %s" % verdict)


if __name__ == "__main__":
    main()
