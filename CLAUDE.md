# CLAUDE.md — `dictate`

Native macOS push-to-talk dictation. Captures the mic (AVFoundation), transcribes
locally with whisper.cpp (libwhisper, Metal), shows a banner while you speak, then
opens a **foreground voice-editor** to review/correct the transcript — navigate by
word, fix any word by voice (a mini-dictation) — and on accept **pastes** into the app
that was focused before the take. Fully self-contained: the daemon owns the ⌘⇧D hotkey,
the banner, the editor, auto-paste, and the menubar indicator **natively** — it replaces
both the old bash script (`~/.local/bin/voice-dictate`) and its Hammerspoon UI layer.
Owner dictates in **Russian**; UI strings are Russian, code/docs English.

The whole reason this exists in C++ instead of the shell pipeline: a **resident
daemon** keeps the model in GPU memory (no per-take reload) and enables
**streaming** (transcribe while you speak).

## Deep dives (read on demand, not auto-loaded)

Long-form rationale lives in `docs/` so this file stays lean. **Read the file for an area
before changing it** — each one is the hard-won part:

- `docs/audio-capture.md` — `StreamingSession` (VAD segmentation, worker, alloc-free tap),
  `Recorder` (one `AVAudioEngine` per daemon, built-in-mic pin, HAL recovery, `audio-poisoned`).
- `docs/voice-editor.md` — `EditorView`/`EditModel`, mini-takes, confidence highlight, undo,
  accept→paste, ⌘⇧D routing.
- `docs/native-ui.md` — hotkeys (why keycode 2, why ⌥⌘⇧D is never unregistered), banner,
  auto-paste, menubar (why an SF Symbol, why common run-loop modes).
- `docs/self-recovery.md` — restart, watchdog, take-start deadline, wedge `sample`, backoff,
  stamped logs, the known restart race.
- `docs/status.md` — what is done, in order.

## Layout

- `src/dictate.mm` — the entire program (Objective-C++). One file on purpose.
- `src/dictate_*.h` — pure, platform-independent logic factored OUT of `dictate.mm` so it's
  unit-testable without AppKit/AVFoundation/whisper/Accelerate (gotcha #19). `dictate.mm`
  `#include`s them, so there's one definition: `dictate_wav.h` (WAV reader), `dictate_text.h`
  (`normalize_ws` + `normalize_text` — the post-normalizer: capitalization/punctuation/
  typography, applied to the final transcript), `dictate_proto.h` (socket verb parse), `dictate_vad.h` (energy-VAD
  `Segmenter` + the VAD tuning constants + cap arithmetic), `dictate_editmodel.h` (editor
  tokenize/cursor/apply + line-nav search), `dictate_authgen.h` (peer-uid + paste-gen checks),
  `dictate_dict.h` (user-dictionary parse + token-budgeted `initial_prompt` build — gotcha #21),
  `dictate_idle.h` (idle-unload gate + poll-cadence arithmetic — gotcha #7),
  `dictate_watchdog.h` (main-thread watchdog gate: heartbeat staleness + poll cadence, the
  take-start deadline arithmetic, and which restart reasons are worth a `sample` snapshot),
  `dictate_edscroll.h` (editor vertical-scroll clamp / cursor-follow arithmetic),
  `dictate_capture.h` (stop-action gate + banner text assembly), `dictate_log.h` (NDJSON
  take-log serialization + the 7-day retention rule).
- `tests/` — doctest unit tests (`tests/doctest.h` vendored; `tests/test_*.cpp`). `make test`.
- `Makefile` — clang++ build; bakes `-DGGML_LIBEXEC` from `brew --prefix ggml`. Also the
  `test` target (host `c++`, no brew/whisper needed — gotcha #19).
- `com.user.dictate.plist` — LaunchAgent template (installed copy in
  `~/Library/LaunchAgents/`; it runs the binary from `~/.local/bin/dictate`, NOT the
  repo build — gotcha #13).
- `README.md` — user-facing; this file is for working ON the code.

## Build / run / test

```sh
make                       # → ./dictate   (needs Xcode CLT + `brew install whisper-cpp`)
make test                  # → tests/run   (doctest; host c++, NO brew/whisper — runs on Linux too)
./dictate --file a.wav     # one-shot, no daemon: stream a 16 kHz mono WAV
./dictate --file a.wav --once   # single-pass (A/B vs streaming)
```

`make test` unit-tests the pure logic in `src/dictate_*.h` (WAV parse, VAD/segmentation,
editor model, socket parse, peer-auth, paste-gen, dictionary→prompt). It links nothing macOS-specific, so it
is the fast inner loop AND the only part that builds off a Mac. It does NOT exercise the
`dictate.mm` macOS build — keep `make` + `make tsan|asan` + `--file`/`feedfile` for that
(gotcha #19).

Make a test clip without a mic (silence hallucination needs *real* noise, not
digital zeros — `anullsrc` won't reproduce it; use a real recording or `anoisesrc`):

```sh
say -v Milena -o /tmp/t.aiff "Привет, это тест"
ffmpeg -i /tmp/t.aiff -ar 16000 -ac 1 -y /tmp/t.wav
./dictate --file /tmp/t.wav
```

Exercise the **daemon** path without a mic via the `feedfile` debug command:

```sh
printf 'feedfile /tmp/t.wav\n' | nc -U /tmp/dictate.sock   # → ok (take left open)
printf 'stop\n'                | nc -U /tmp/dictate.sock   # → streamed transcript
```

## CLI / protocol

Normal use is the **⌘⇧D hotkey owned by the daemon itself** — no client needed.
The client verbs remain for scripting/tests: `start stop cancel ping restart quit`.
`stop` prints the transcript to stdout (the daemon also copies it to the clipboard
and auto-pastes). `--file [--once] [--lang xx] [--model P]` is the standalone path:
`--file` streams (VAD-segmented) like a take, `--once` does a single whole-buffer pass
(the A/B reference). Run TSan/ASan over `--file` to cover the tap↔worker concurrency.

Daemon socket commands (newline-terminated, raw replies): `ping`→`pong`,
`start`→`ok`/`err …`, `stop`→transcript (script/test path: clipboard, **no** editor),
`cancel`→`ok`, `feedfile <path>`→`ok`, `restart`→`ok` (relaunch the daemon process — graceful
via the main queue, force-restarted from the socket thread after 2 s if main is wedged),
`wedge <sec>`→`ok` (debug: block the main queue, the only way to exercise the watchdog /
force-restart e2e — **gated on `DICTATE_DEBUG`**, otherwise `err unknown`),
`reconfig`→`ok` (debug, same gate: run the route-change path — `Recorder -reconfigure`, which drops
and rebuilds the engine — without physically unplugging anything; works both idle and mid-take),
`quit`→`bye`.
The take-start deadline has its own e2e hook for the same reason (nothing else hangs the mic
start on demand): `DICTATE_DEBUG_TAKESTART_STALL=<sec>` (with `DICTATE_DEBUG`) stalls inside the
armed window, on the main queue, under `g_mu` — start a take and the daemon restarts with reason
`take-start` and leaves a `/tmp/dictate-wedge-*.txt` naming `daemon_start`.
`DICTATE_DEBUG_POISON=1` (with `DICTATE_DEBUG`) is the same kind of hook for the deferred
`audio-poisoned` restart: every successful mic start reports a fake `kAudioHardwareIllegalOperationError`,
so a take + cancel is enough to watch the daemon wait out the take and then restart while idle.
Each connection is served on **its own thread** (`socket_accept_loop`, capped at
`SOCK_MAX_INFLIGHT`): most verbs `dispatch_sync` to the main queue, so serving inline meant one
client blocked on a wedged main thread starved the accept loop and `restart` — the verb whose
job is to break that wedge — was never even read. Editor protocol (daemon ↔ the
`dictate editor` process): `corr-start`→`ok` (mini-take mic on), `corr-stop`→transcript,
`corr-cancel`→`ok`, `accept <text>`→`ok` (refocus target + paste), `editor-cancel`→`ok`,
`edit <text>`→`ok` (debug: open the editor on text, no mic). Standalone:
`dictate editor "слова"` runs the editor alone (stubbed mini-take). Socket
`/tmp/dictate.sock` (override `$DICTATE_SOCK` to run a test daemon off the live one) ·
logs `/tmp/dictate.log`, `/tmp/dictate-editor.log`.

## Architecture

- **Daemon** (`run_daemon`): a Cocoa **accessory** agent. Single instance (guards
  via socket ping), binds the socket, loads ggml backends + the model **once**, then
  the **main thread runs `[NSApp run]`** (for the hotkey + banner + menubar) while a
  **background thread** serves the Unix socket (`socket_accept_loop`/`serve_client`).
  Holds `g_ctx` (model), `g_sess` (current take), `g_rec` (mic). The recording
  lifecycle + all AppKit live on the main queue; the socket thread and the worker
  marshal there via GCD. `stop`'s blocking `finish()` runs **off-main** so the run
  loop never freezes.
- **Client** (`client_cmd` / `ensure_daemon`): `start` auto-spawns the daemon
  (fork+setsid+exec, logging to `/tmp/dictate.log`) if none answers, then polls
  ~6 s for it to come up (covers the model-load window).
- **StreamingSession**: energy-VAD segments the 16 kHz mono stream at pauses; **one worker
  thread** runs `whisper_full` per closed segment and appends text in order — that's the
  streaming win: on stop only the open tail is left for `finish()`. No live interim text (the
  words surface in the post-take editor). Fixed cost: whisper's encoder always processes a
  30 s window, so every `whisper_full` costs ~1.1 s on M1 Pro regardless of segment length —
  the floor for stop latency. Details → `docs/audio-capture.md`.
- **Recorder** (`AVAudioEngine`): **one engine per daemon**, not per take (gotcha #25) — the
  `inputNode`/`GetHWFormat` wedge site runs once per process. Capture is **pinned to the
  built-in mic** (gotcha #22); a route change drops and rebuilds the engine; a stale HAL
  client (`kAudioHardwareNotRunningError`) rebuilds once (gotcha #23); a
  `kAudioHardwareIllegalOperationError` books a restart for the next idle moment
  (`g_audio_poisoned`). Every mic start logs its timings. Details → `docs/audio-capture.md`.
- **whisper's built-in Silero VAD** is enabled in `make_params` on top of all
  that — it trims silence *inside* each segment (see gotcha #3).
- **Native UI** (`DictateController`, the `NSApp` delegate): owns the global ⌘⇧D
  hotkey (Carbon `RegisterEventHotKey`, keycode 2) + scoped Esc-cancel, the floating
  banner (`NSPanel`), auto-paste (synthetic ⌘V via `CGEvent`), and the menubar
  `NSStatusItem` + 60 s auto-stop timer — all on the main thread. → `docs/native-ui.md`.

## Voice editor (post-take correction)

After a take the daemon opens a **foreground editor** (`dictate editor`, a separate process —
a dedicated KEY window composites reliably where the background banner did not) instead of
pasting directly: navigate by word (←/→ ↑/↓), fix a word by voice (SPACE = mini-take via
`corr-start`/`corr-stop`), ⌫/⌦ delete, ⌘Z/⌘⇧Z undo/redo, ⏎ or ⌘⇧D accept → daemon refocuses
the app that was frontmost at take start and pastes; Esc cancels. Accessory app +
**non-activating `NSPanel`** so it surfaces on the current Space (gotcha #20). The daemon
unregisters ⌘⇧D while the editor is open and recovers via `waitpid` if the editor dies
(gotcha #15). Transcript travels over the editor's stdin (`--stdin`), per-word confidence over
`--conf` argv; pure model in `src/dictate_editmodel.h` + `src/dictate_conf.h`, unit-tested.
Everything else → `docs/voice-editor.md`.

## Architecture decisions & gotchas → Notion

The hard-won macOS / whisper / concurrency **gotchas** that used to fill this section
were really ADRs, so they now live in Notion (one ADR per gotcha) to keep this file lean:

→ **[Dictate ADRs](https://app.notion.com/p/164ad9f8d7ad4529a6291b9039aa45e2)**
(HQ › Projects › [Dictate](https://app.notion.com/p/379e684244ab81b196abcc223eb8bb56);
also indexed in the HQ **ADR Registry**).

Numbering is preserved one-to-one: **gotcha #N ≡ ADR-00NN** — so the many `gotcha #N`
cross-references still scattered through this file resolve to ADR-00NN in that database
(e.g. `gotcha #5` = ADR-0005, whisper_context thread-safety; `gotcha #14` = ADR-0014, signing).
Read the relevant ADR before changing that area, and record the next hard-won lesson as a
**new ADR there**, not as a new gotcha here.

## Native UI + self-recovery (summary)

All UI on the **main thread** in `DictateController`. Hotkeys ⌘⇧D (toggle), Esc (cancel,
registered only during a take), ⌥⌘⇧D (restart, never unregistered — but Carbon delivers to the
main run loop, so it is dead when main is wedged). Status-only banner (`BANNER_*` constants).
Menubar: SF Symbol glyph, left-click toggles, right-click menu with state / ⟳ / log; timers in
`NSRunLoopCommonModes`. → `docs/native-ui.md`.

Recovery = a fresh process (`restart_process_now`: takes no locks, spawns the successor first,
allocates nothing). Triggers: menubar ⟳ / ⌥⌘⇧D / `restart` verb (graceful, forced after
`RESTART_DEADLINE_SEC`), the heartbeat **watchdog** (`DICTATE_WATCHDOG_SEC`, `CLOCK_UPTIME_RAW`,
common modes, checker-starvation + long-op guards), the **take-start deadline**
(`DICTATE_TAKESTART_SEC`, around the mic-start critical section only), and the deferred
`audio-poisoned` restart. Involuntary restarts `sample` the process first
(`~/.local/share/dictate/wedge/`), aborted restarts back off. Every daemon log line is stamped
`HH:MM:SS.mmm` via `write(2)`, never stdio. Pure gates: `src/dictate_watchdog.h`.
→ `docs/self-recovery.md` before touching any of it.

## Daemon lifecycle (LaunchAgent)

Auto-starts at login as a **user LaunchAgent** (`com.user.dictate`, RunAtLoad +
KeepAlive). It must be a user agent, not a system LaunchDaemon — it needs the user's
mic, clipboard, and GUI session. The plist runs the **installed copy at
`~/.local/bin/dictate`**, not the repo build (gotcha #13).

**One-shot deploy:** `make deploy` (or `scripts/deploy.sh`) does the whole dance —
`make test` → `make` → install to `~/.local/bin` → `launchctl kickstart -k` →
`scripts/post-build-check.sh` (waits for the daemon to come up, then verifies binary/signature/
LaunchAgent/ping/Accessibility). Flags: `scripts/deploy.sh --no-test` / `--no-check` (or
`make deploy ARGS=--no-test`). The manual steps below are the underlying commands.

```sh
make && cp dictate ~/.local/bin/dictate          # build + install (NOT into ~/Documents — gotcha #13)
sed "s|/Users/YOUR_USERNAME|$HOME|" com.user.dictate.plist > ~/Library/LaunchAgents/com.user.dictate.plist  # launchd won't expand ~
# macOS 14+: bootstrap/bootout (legacy `load -w`/`unload` are deprecated — gotcha #13).
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.user.dictate.plist  # enable + start
launchctl bootout   gui/$(id -u)/com.user.dictate                              # stop + disable
launchctl kickstart -k gui/$(id -u)/com.user.dictate                           # restart (pick up a new build)
launchctl print gui/$(id -u)/com.user.dictate | grep -E 'state|pid'            # status
tail -f /tmp/dictate.log                                                       # logs
```

If you see two daemon processes, you have a stray (manual or pre-LaunchAgent
auto-spawn). Clean: `launchctl bootout gui/$(id -u)/com.user.dictate; pkill -9 -f
'dictate daemon'; rm -f /tmp/dictate.sock; launchctl bootstrap gui/$(id -u) …`.

## Config (env) & tuning

- `WHISPER_MODEL` (default `~/.config/whisper/ggml-large-v3-turbo-q5_0.bin`),
  `WHISPER_LANG` (default `ru`), `WHISPER_VAD_MODEL` (default
  `~/.config/whisper/ggml-silero-v6.2.0.bin`, falling back to `ggml-silero-v5.1.2.bin` when
  only that one is on disk — set the var to roll back), `WHISPER_VAD=0` to disable
  VAD, `DICTATE_GGML_BACKENDS` to override the backend dir, `DICTATE_SOCK` to override
  the socket path (run a test daemon off the live one).
- `DICTATE_BUILTIN_MIC=0` — stop pinning capture to the built-in mic and follow the system
  default input instead (default ON; the pin is what keeps takes off BlackHole / Teams Audio
  / AirPods — gotcha #22). No-ops on a Mac with no built-in input, keeping the default. Note
  it overrides an external mic you actually chose, and since the daemon is launchd-started,
  `export`ing it in a shell does nothing — opting out means an `EnvironmentVariables` dict in
  `~/Library/LaunchAgents/com.user.dictate.plist` + `launchctl bootout`/`bootstrap`. (Same for
  every other var here when the daemon runs under the LaunchAgent.)
- `WHISPER_DICT` (default `~/.config/whisper/dictionary.txt`) — user dictionary that biases
  whisper toward your vocabulary (names / tech terms / English-in-Russian) via `initial_prompt`.
  Default ON if the file exists; `WHISPER_PROMPT=0` disables it (like `WHISPER_VAD`/`WHISPER_FLASH`);
  `WHISPER_PROMPT_MAXTOK=N` overrides the ~224-token budget. One entry/line, order = priority,
  `#` comments; assembled by `src/dictate_dict.h` (gotcha #21). Template: `examples/dictionary.txt`;
  WER harness: `scripts/bench-wer.py`.
- `WHISPER_FLASH=0` disables Metal flash attention (on by default; ~20% faster
  transcription on the turbo model, output unchanged — see gotcha #11).
- `DICTATE_NORMALIZE=0` disables post-normalization of the final transcript (default ON).
  The normalizer (`normalize_text`, `src/dictate_text.h`) capitalizes sentence starts, fixes
  punctuation spacing, and applies light typography (`...`→`…`, ` - `→` — `) — conservative
  by design (leaves mixed RU/EN, domains, file names, versions, decimals alone). It is applied
  via `finalize_transcript()` ONLY at the two final take boundaries (the hotkey/timer worker
  after `raw->finish()`, and the socket `stop` after `s->finish()`) — **never inside `finish()`
  itself**, because `finish()` is shared with the editor mini-take (`corr-stop`), where a
  single-word voice correction must stay verbatim (sentence-capitalizing a one-word replacement
  would be wrong). The standalone `--file` path is left raw (it's the A/B reference).
- `WHISPER_THREADS=N` overrides the CPU-thread count. Default = performance-core
  count (`hw.perflevel0.physicalcpu`), not all logical cores: the workload is
  GPU-bound so thread count barely matters, and this keeps whisper off the E-cores.
- `DICTATE_IDLE_UNLOAD_SEC=N` (built-in default OFF / `0`, **`3600` in the installed plist**) —
  free the ~573 MB resident model after N seconds with no take, reloading on demand on the next
  take (~300–600 ms, on the main queue, BEFORE the mic starts — ten times the mic start itself).
  Trades the resident-speed win for memory when idle (gotcha #7). The plist used to say 300 s,
  and over a week that made 8 of 10 takes pay the reload (measured 2026-09-02); an hour keeps
  the model warm through a working session and still frees it overnight. The idle gate
  (`src/dictate_idle.h`, unit-tested — gotcha #19) is polled by an `NSTimer` at
  `idle_poll_interval_sec(N)` (timeout/3, clamped to 1–10 s).
- `DICTATE_LOG=1` (default OFF, **on in the installed plist**) — owner-only daily NDJSON take
  logs under `~/.local/share/dictate/logs/YYYY-MM-DD.ndjson` (0600): take start/cancel, raw +
  normalized transcript, editor accept/cancel, each mini-take correction with what it replaced.
  Pruned to 7 days at daemon start (`TakeLogger::prune`, pure rules in `src/dictate_log.h`).
  It is the corpus for WER work and for reconstructing what a take produced.
- `DICTATE_WATCHDOG_SEC=N` (built-in default `30`, **`15` in the installed plist**, `0` = off,
  values < 10 clamp up to 10) — restart the daemon if the main run loop stops stamping its 1 Hz
  heartbeat for N seconds. The pure gate is `src/dictate_watchdog.h` (unit-tested); see the
  Native-UI section for the false-positive traps (common run-loop modes, sleep-excluding clock,
  checker starvation, long-op exemption).
- `DICTATE_TAKESTART_SEC=N` (default `8`, `0` = off, values < 3 clamp up to 3 — gotcha #24) — restart the daemon
  if the mic-start section (`AVAudioEngine` build + built-in-mic pin + engine start, main queue,
  `g_mu` held) does not return within N seconds. Tighter than the heartbeat on purpose — see the
  Native-UI section. Off when the watchdog is off.
- `DICTATE_DEBUG_POISON=1` (debug, needs `DICTATE_DEBUG`) — fake a `kAudioHardwareIllegalOperationError`
  on every successful mic start, to exercise the deferred `audio-poisoned` restart (gotcha #25).
- `DICTATE_WEDGE_SAMPLE=0` — skip the `/usr/bin/sample` snapshot taken before an involuntary
  restart (default ON, writes `~/.local/share/dictate/wedge/wedge-<epoch>.txt`). The snapshot costs
  ~1.5 s of an already-broken daemon's restart and is the only source of the stuck stack.
- VAD/segmentation constants in `src/dictate_vad.h` (with the pure `Segmenter`):
  `SILENCE_CLOSE_FR` (~700 ms pause closes a segment), `SPEECH_FACTOR`/`ABS_FLOOR`
  (sensitivity), `MAX_SEG_FR` (~20 s hard cap), `PREROLL_FR` (~300 ms kept before onset),
  `SPEECH_CONFIRM_FR`, `FRAME`. The Silero VAD params live in `make_params`
  (`min_silence_duration_ms`, `speech_pad_ms`).

## whisper.cpp notes (Homebrew 1.9.2)

API used: `whisper_init_from_file_with_params` (+ `whisper_context_default_params`,
`use_gpu=true`), `whisper_full_default_params(WHISPER_SAMPLING_GREEDY)`,
`whisper_full`, `whisper_full_n_segments`, `whisper_full_get_segment_text`,
`whisper_free`. VAD via `whisper_full_params.{vad,vad_model_path,vad_params}` +
`whisper_vad_default_params`. Lexical bias via `whisper_full_params.initial_prompt` (a
non-owning `const char*`, backed by the `g_initial_prompt` global — gotcha #21). Headers:
`$(brew --prefix whisper-cpp)/include`;
`ggml.h` from `$(brew --prefix ggml)/include`.

## Status / roadmap

Done list (in order) → `docs/status.md`.

Declined: warm-mic option (pre-open device to kill the ~0.5–1.5 s avfoundation warm-up) —
deliberately not pursued; don't re-propose.

Editor follow-ups (minor, not blocking): make editor-after-every-take optional if it feels
heavy; `relayout` re-measures on every `drawRect` (cheap at current word counts). (The in-take
banner live-preview is gone entirely now — the banner is status-only.)
