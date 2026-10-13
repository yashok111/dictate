# Local meeting transcriber

A separate native Mac app for importing audio/video, recognizing Russian speech
with English terms, and reading a transcript grouped by speaker. All inference
runs locally. Dictate's existing daemon is independent of this application.

This is a developer preview, **not an enterprise release**. The UI and native
pipeline work together; the model pair and memory budgets still need evaluation
on real one-hour, 5–10-speaker meetings and on an 8 GB Mac.

## Install from DMG

The packaged app requires **Apple Silicon and macOS 26 or later**. Open
`Transcriber-0.2.5-arm64.dmg`, drag Transcriber into Applications, and open it.
Homebrew, Python, and developer tools are not required on the destination Mac.

On first launch, choose **Скачать и начать**. Turbo Q5 and the shared speech/voice
models download through public Hugging Face and GitHub sources (about 914 MB transferred and installed). Downloads use HTTPS and files are verified with SHA-256 before
use. Audio and transcripts are not uploaded. After installation, recognition works
offline. Existing transcripts can be read/exported without installed models.

Models download from public sources. Pinned revisions, sizes and SHA-256 checks are preserved. Already installed models remain usable offline.

Use **Модели…** to pause, continue, retry, or delete a model. The optional full
large-v3 model adds about 3.1 GB and remains an explicit selection. A resume may
restart its current file when the server or macOS no longer has resumable data;
already verified files are reused. Imports wait in the queue while a required
model is missing. Model files live under
`~/Library/Application Support/Dictate Transcriber/Models`; replacing the app
preserves them and your recordings. Active models cannot be deleted.

The **Turbo · без сжатия (FP16)** download option is the unquantized Turbo
model (1.62 GB of weights, about 1.65 GB including shared models). It reuses any
shared models already installed. After downloading, select it in the sidebar's
model menu; automatic selection continues to use Turbo Q5. Its provisional
processing budget is 3 GB plus the separate 0.5 GB reserve.

The default local DMG is **ad-hoc signed, not notarized**. Gatekeeper may require
manual approval in macOS Privacy & Security when the app is downloaded from
another computer. Developer ID signing/notarization is an optional release mode.
The build audits all bundled runtime dependencies, but a developer-machine check
does not substitute for qualification on a separate clean Mac.

## Build and run

Requires Apple Silicon, current macOS and Command Line Tools with Swift, Homebrew
`whisper-cpp`/`ggml`, and Python 3.12+ for dependency setup. Setup downloads the
pinned Community-1 diarization models, plus 574 MB for
Turbo Q5 weights; SHA-256 is verified for every download.
The development setup provisions models locally. Packaged builds offer downloads
in the app; inference makes no network calls.
Setup also includes the pinned, SHA-256-verified Silero GGML v6.2.0 model (885 KB).

From the repository root:

```sh
python3 transcriber/scripts/setup-deps.py
python3 transcriber/scripts/setup-large-v3.py --turbo
bash transcriber/scripts/build-app.sh
open transcriber/build/Transcriber.app
```

The default developer bundle uses model and runtime paths on the build machine.
To build a relocatable app and DMG instead:

```sh
bash transcriber/scripts/build-dmg.sh --mode adhoc
```

This builds `transcriber/build/release/Transcriber.app`, embeds the complete
Whisper/ggml/Metal and the native Swift Community-1 helper and notices, audits dependencies and the
macOS 26 deployment floor, signs nested code, and writes the versioned DMG under
`transcriber/build/`. Model weights are excluded. The build needs the development
dependencies listed above and Swift 6.2 or later for the pinned FluidAudio package.
DMG packaging also needs a logged-in macOS GUI session and permission for the
terminal to control Finder. It saves a compact installation window with a Retina
background and fixed app → Applications positions before compressing the image.
The background is drawn by `scripts/draw-dmg-background.swift`; Finder layout lives
in `scripts/layout-dmg.applescript`. These build tools are not needed to install.

For a configured Developer ID identity, select `--mode developer-id` and set
`TRANSCRIBER_SIGN_IDENTITY`. Explicit `--notarize` additionally uses
`TRANSCRIBER_NOTARY_PROFILE`, a preconfigured keychain profile; it submits the app
and DMG to Apple and staples their tickets. A requested release signature never
silently falls back to ad-hoc signing. No signing credentials are stored here.

The fast **Быстрый · Turbo Q5** profile uses quantized Q5_0 weights from
`transcriber/.models/ggml-large-v3-turbo-q5_0.bin`. Its provisional 3 GB processing
budget plus 0.5 GB reserve must fit current headroom (3.5 GB total). The floor
allows for long-recording PCM buffers and Community-1 clustering; it is not a
measured four-hour bound. Short-clip Community-1 inference peaked around 246 MB
footprint; the earlier ASR benchmark reached about 1.04 GB RSS. Turbo FP16 and the full large-v3 profile below
are also available by explicit selection. The optional economy profile
expects `transcriber/.models/ggml-small-q5_1.bin`. Missing profiles cannot run.
Paths and provisional memory budgets are generated by `scripts/write-bundle.py`
into `Contents/Resources/runtime.json`; change the build configuration and rebuild
to use different locally provisioned models. Models are not committed to Git.

An optional full Whisper large-v3 FP16 profile can be installed explicitly:

```sh
python3 transcriber/scripts/setup-large-v3.py
bash transcriber/scripts/build-app.sh
```

This downloads about 3.1 GB into `.models/`, using a pinned upstream revision
and SHA-256 verification. In the sidebar, select **Полный · large-v3** before
importing a recording. Its provisional 4.5 GB processing budget plus 0.5 GB reserve
must fit current headroom (5 GB total). Local benchmark peaks were 3.74–3.91 GB;
the budget includes margin beyond those runs but still needs qualification on
hour-long meetings and 8 GB Macs. Memory-pressure protection remains active.
This profile is excluded from automatic selection
until representative accuracy and memory qualification is complete. A larger
model is not a guarantee of a better transcript. The selector affects queued jobs
when they start, including retries; existing results are retained.

To compare the installed full model and Turbo sequentially on the same input:

```sh
python3 transcriber/scripts/bench-models.py /path/to/meeting.mp4 transcriber/build/comparison
```

Use a new output directory for each comparison. It retains separate transcripts,
timed progress events, worker diagnostics, and elapsed-time/peak-memory summaries.
This is a developer CLI: unlike the app it does not supervise memory pressure;
run it only with enough memory for the selected profiles. Comparison of two
transcripts measures disagreement, not word error rate against human reference.
Pass `--no-vad` to compare against unfiltered ASR. Use the same decoded PCM WAV
for exact output comparisons: independently decoding AAC can produce small differences.

## Use

On macOS 26 and later, actions, playback controls and search use native Liquid
Glass. Transcript text retains a solid reading surface. Older systems use native
bordered controls and material backgrounds; custom surfaces respect Reduce
Transparency, while native controls follow the system accessibility settings.
Short transitions soften transcript appearance, progress updates
and file-drop feedback. Play/pause symbols transition on macOS 14+. These custom
animations respect Reduce Motion; search results and recording selection update
immediately.
Appearance follows macOS. With no recording selected, the welcome screen shows
a labeled example of speaker-separated text in the same document layout as real
transcripts. The example is static UI content and is never added to the library.
The transcript's left timeline follows the height of each text fragment and uses
its speaker's color (gray for unknown speakers). Click a timecode to play from
that original source offset. Search preserves those offsets; the rail is a reading
guide, not a duration-proportional waveform.

Choose **Загрузить запись** or drop a file to open **Контекст встречи**.
Optionally enter a short, comma-separated list of participants' names, company
names and specialist terms likely to occur in the recording (up to 300 characters),
then choose **Начать расшифровку**. For example: `Анна Смирнова, Алексей,
TestFlight, onboarding, API`. There is no need to fill the character allowance;
leave it empty for ordinary recognition.
For a multiple-file selection, the same context applies to every selected file.
Context is stored locally with each recording and can be viewed below its title.
Repeating transcription pre-fills it and allows editing or clearing it; the old
recording and its context remain intact. Retrying a failed job also allows editing.

The context is vocabulary guidance, not an instruction to summarize the meeting.
It is passed verbatim in an owner-only attempt file, separate from Dictate's
personal dictionary. Whisper checks its actual token budget and rejects an
oversized hint rather than silently dropping part of it; shorten it and retry.
The 300-character UI limit is separate from Whisper's 224-token budget: tokens
can be word fragments, so a hint may still need shortening after tokenization.
The app does not include the context text in worker arguments or diagnostic logs.

A private source copy is retained
under `~/Library/Application Support/Dictate Transcriber`. One job runs at a time;
recognition runs first and releases its model before speaker analysis starts.
The text then appears as a read-only preview, with search and playback available.
Speaker assignment, renaming and export become available after speakers are ready.
Transcript text remains read-only and can be selected and copied. Processing is in
a separate process, so cancellation does not freeze the interface.

Before recognition, Silero runs locally on one CPU thread. It skips a whole
25-second Whisper window only when every 32 ms frame has speech probability
below 0.10, including Whisper's context and an extra second on either side.
Any detected or uncertain speech keeps the window; windows shorter than five
seconds also stay. Missing models, invalid output or inference errors keep all
windows. At runtime, only bytes matching the pinned model's SHA-256 are loaded;
damaged or unsupported model files disable VAD. Audio is never concatenated, timestamps retain their original offsets,
and speaker analysis still receives the full original audio. The VAD context is
released before Whisper loads. Long quiet stretches can save recognition work;
continuous speech pays the extra VAD scan cost. This detects speech, not denoising.
`prepare.log` records scan time and skipped windows. The native CLI accepts
`--vad-model PATH`; omitting it disables VAD. The app uses `runtime.json`'s
optional `vad` path automatically.

Speaker analysis uses **Community-1 through FluidAudio**, fully on-device:
powerset segmentation, WeSpeaker embeddings, PLDA and VBx clustering. The native
Whisper process exits before the Swift diarizer loads models. A final native
stage assigns the resulting turns to individual word timestamps. Words at ASR
window boundaries retain midpoint ownership and recognition order; their spans
are clipped to the owning 25-second core to prevent context timestamps from
moving backwards. Each stage is a
direct child of the app, sharing one cancellation token and model lease.
Version 0.2.3 also preserves recognized words with zero-duration Whisper
timestamps. Such words accompany the next timed word in recognition order;
trailing runs with no reliable span remain visible without a guessed speaker.
This fixes dropped text such as short “да” responses, not mistaken speaker
identities from the diarization model.
Version 0.2.4 also assigns reliably timed words up to one second long to a
unique nearby voice across gaps up to 0.5 seconds or weak partial coverage.
Competing nearby speakers, overlap and uncertain timing remain unassigned.
It conservatively rechecks exclusive 0.8–4 second turns against stable voice
references from the full recording (at least three consistent reference spans).
Only cosine similarity of at least 0.6 with a 0.2 advantage over every other
profile can change an identity. These scores are not calibrated probabilities.
Rare voices with insufficient reference speech and ambiguous matches retain
their original labels. The new configuration invalidates old speaker-cache
entries; a failed optional recheck retains base results without caching them.
Diagnostics are in `prepare.log`, `diarization.log` and `finalize.log`.

The SDK revision and model files are pinned in `Resources/community-1.lock.json`.
The four Core ML directories plus PLDA parameters download as verified individual
files through public sources. An incomplete directory never becomes ready. Inference loads
only local files; missing/corrupt models fail instead of reverting to sherpa.
The Core ML conversion is not numerically identical to official PyTorch, and
published Community-1 DER scores are not measurements of this app. Window shift
is 0.1. Version 0.2.2 lowers the minimum speech-segment duration to 0.5 seconds
and enables zero-vote re-embedding for runs of at least 0.4 seconds. These are
trial settings for short replies and spans without embedding votes; improved
assignment accuracy has not yet been established against a human reference.
Clustering threshold 0.6, Fa 0.07 and Fb 0.8 retain the pinned SDK defaults;
speaker count stays automatic. The configuration fingerprint invalidates old
speaker-cache entries. For a diagnostic CPU comparison, invoke `transcriber-diarizer` with
`--compute-units cpu` (default `all`).

Raw turns use the separate `.speaker-cache/community-1-v1` namespace. Source and
model content hashes, SDK revision, inference settings, compute units, decode
version and OS identify entries. Old sherpa cache entries are never reused.
Changing Whisper can reuse Community-1 turns. Existing transcripts and speaker
edits stay intact; explicitly repeat transcription to apply the new engine.

Developer stage protocol:

```sh
mkdir -p /tmp/transcriber-attempt
build/transcriber-worker --prepare input.wav .models/ggml-large-v3-turbo-q5_0.bin /tmp/transcriber-attempt
build/community-1/transcriber-diarizer --attempt-dir /tmp/transcriber-attempt --model-dir .models/community-1 --model-manifest Resources/community-1.lock.json --cache-dir /tmp/transcriber-cache
build/transcriber-worker --finalize /tmp/transcriber-attempt
```

The app removes temporary PCM/word/turn files on completion/cancellation and
recovers abandoned attempt intermediates at startup. Source media, logs and
saved transcripts are preserved.

The cache contains no edited transcript and can be deleted when no job is active.
CLI/benchmark use is opt-in with `--cache-dir PATH`; the app enables it automatically.

Choose the model in the sidebar, then use the circular-arrow button beside Export
to transcribe a ready recording again. This creates a separate record and preserves
the original edits and speaker names.

Use the trash button in the recording header or **Удалить расшифровку…** in the
sidebar context menu. After confirmation the recording, its private media copy
and processing files move together to macOS Trash. The original imported file,
other recordings and shared speaker cache stay in place. An active worker is
stopped before its files move; queued recordings continue processing afterwards.
Deletion is unavailable while a source file is being copied.

Click a timestamp to listen and use the speaker menu to rename/reassign a voice.
Export TXT, SRT, or JSON. Machine output stays in its attempt directory; speaker
changes are saved in the library document. Restarting the app marks
unfinished processing as interrupted and offers retry.
Unreadable recording metadata is reported without blocking healthy recordings;
its files remain available for recovery. Failed imports remove their unpublished
private copy. If saving a processing state fails, the app shows an error and
requires an explicit retry instead of repeatedly launching recognition.

Speaker names are manual. The engine estimates the number of voices; it does not
force the expected 5–10 participants onto every file. Overlapping or ambiguous
intervals can retain an unknown speaker label. Input longer than four hours is
rejected explicitly in this preview; this is a resource guard, not a claim that
four-hour quality/performance has been validated. Only the first audio track is
decoded; importing multiple participant tracks is future work.

Closing the window leaves the process running; quitting cancels active work.
After a memory-pressure stop, use **Повторить** when resources are available.
Retry starts a fresh ASR attempt and reuses valid cached speaker turns. Recognition
itself does not yet resume from interrupted chunks.
Normal quit terminates the worker; automatic worker cleanup after an application
crash still needs implementation and testing.

## Verify

```sh
make test
bash transcriber/scripts/test-swift.sh
make -C transcriber test
bash transcriber/scripts/test-model-downloads.sh
python3 -m unittest discover -s transcriber/tests -p 'test_bundle_runtime.py'
python3 -m unittest discover -s transcriber/tests -p 'test_release_scripts.py'
```

The first command runs the existing portable C++ suite plus model-admission and
speaker-attribution cases. Swift tests cover the C ABI, transcript validation,
exports, persistence, preview cancellation, repeating without overwriting edits,
stale-attempt rejection, failed state saves, shutdown, corrupt-record isolation,
and import ownership/cleanup. Native tests cover cache invalidation/corruption,
word attribution after preview, invalid input, paths with spaces/Cyrillic
characters, and silent audio.
Legacy noise-reduction settings are ignored while preserving saved transcripts;
noise reduction is no longer part of the processing pipeline.
AVFoundation tests require access to macOS media services and may fail inside a
restricted process sandbox.

The app and Foundation tests use `swiftc` directly; the new helper uses SwiftPM.
`bash scripts/test-community-contract.sh` tests the file/turn/cache contract
without XCTest. `bash scripts/test-community-1.sh` exercises installed models
on synthetic Russian speech. Both are separate from real-meeting quality evaluation.

On the development machine, a stale 2024 private PackageDescription interface
shadows the current Swift 6.4 public interface. A temporary VFS overlay can be
passed with `TRANSCRIBER_MANIFEST_OVERLAY`; `SWIFTPM_MODULECACHE_OVERRIDE` selects
a fresh cache. This is a local toolchain workaround, not required on a consistent
Swift installation; build scripts never modify the system toolchain.

## Boundaries and remaining release work

Whisper/ggml come from Homebrew at build time and are bundled for distribution.
Community-1 SDK/model revisions are immutable. Silero uses the pinned GGML 6.2.0
export. No Python inference runtime or sherpa inference library is shipped. ONNX Runtime is bundled for Russian forced alignment.


- `core/`: portable C++17 policy plus a small C ABI consumed by Swift.
- `native/worker.mm`: media decoding, timed ASR, original-word attribution and JSON output.
- `Sources/CommunityDiarizer/`: offline Community-1 inference and speaker cache.
- `Sources/TranscriptKit/`: persistence, exports, memory sampling, process control.
- `Sources/TranscriberApp/`: SwiftUI library, player, transcript viewer.
- Reuses `src/dictate_dict.h` and `src/dictate_text.h` directly. Optional CLI
  dictionary argument uses Dictate's existing hint builder; UI dictionary import
  and uncertain-word highlighting are still pending.

Before employee distribution: qualify both profiles with WER/DER and memory
measurements; validate chunk-boundary alignment and overlap; implement signed
offline model packs and a relocatable notarized app; add durable stage checkpoints,
automatic retention, dictionary UI, DOCX export, and application update handling.
Profile ranks and budgets are provisional; a large model is not assumed to be
universally more accurate. The current selector estimates free/inactive pages
and responds to memory pressure; it cannot reserve memory against other apps.

Runtime license texts and model-source notices ship in `Resources/ThirdPartyNotices`.
Review redistribution terms separately for runtime and each model. Community-1 model attribution and conversion provenance are included; historical
notices for previous engine releases do not imply they are still linked. No telemetry is implemented by this app.

For a human-labelled quality comparison, create an isolated environment from
`scripts/benchmark-requirements.lock`, then run
`python scripts/bench-diarization.py reference.rttm turns.json`. The tool reports
DER with zero collar and overlapping speech included, plus false-split/merge
diagnostics using at least one second of overlap per label. These Python tools
are development-only and never included in the app. A representative meeting
and manual reference are required before claiming reduced speaker fragmentation.

## Version 0.2.5: alignment and speaker corrections

A native CTC stage refines Russian word timing after Whisper and before speaker
attribution. The shared 317 MB INT8 Wav2Vec2 model downloads through the existing
Models screen; existing ASR and Community files are reused. Updating the app does
not rewrite saved transcripts: repeat transcription to apply alignment. Inference
runs locally in a separate cancellable worker process after Whisper is unloaded.
Non-Russian/unsupported words, uncertain timing, low-scoring windows and model
errors retain original text/times. Blank frames do not extend word ends. Scores
are guardrails, not calibrated accuracy probabilities. Inspect alignment.log for
aligned and retained source-record counts. This improves timing, not the identity
of a speaker that Community classified incorrectly.

Short unknown interior word runs (at most 1.2 seconds) can inherit the same directly
covered speaker on both sides when each word-to-anchor gap is at most 250 ms.
Any competing turn, overlap, unreliable word timing, or different anchor identity
prevents recovery. Recovered words never become evidence for another recovery.

In a ready transcript, click **Выбрать реплики**, tick the desired rows, then use
**Назначить говорящего**. **Объединить соседние** joins affected adjacent rows of
the chosen voice, with a maximum one-second gap and 20-second resulting span.
Overlapping rows remain separate. Search/record changes clear the selection.
**Отменить правку** restores the last assignment/merge or rename, including text,
row boundaries and speaker names. Up to 20 edits per recording can be undone in
the current app session; undo itself is saved to disk. Export reflects saved edits.

Developer setup: `python3 transcriber/scripts/setup-alignment.py` verifies and
installs ONNX Runtime, compatible headers and the pinned model. The standard
setup-deps.py invokes it as well. Pipeline order is prepare → align → diarize →
finalize; `transcriber-worker --align ATTEMPT MODEL.onnx` is the alignment stage.
