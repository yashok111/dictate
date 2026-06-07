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
  `dictate_edscroll.h` (editor vertical-scroll clamp / cursor-follow arithmetic).
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
The client verbs remain for scripting/tests: `start stop cancel ping quit`.
`stop` prints the transcript to stdout (the daemon also copies it to the clipboard
and auto-pastes). `--file [--once] [--lang xx] [--model P]` is the standalone path:
`--file` streams (VAD-segmented) like a take, `--once` does a single whole-buffer pass
(the A/B reference). Run TSan/ASan over `--file` to cover the tap↔worker concurrency.

Daemon socket commands (newline-terminated, raw replies): `ping`→`pong`,
`start`→`ok`/`err …`, `stop`→transcript (script/test path: clipboard, **no** editor),
`cancel`→`ok`, `feedfile <path>`→`ok`, `quit`→`bye`. Editor protocol (daemon ↔ the
`dictate editor` process): `corr-start`→`ok` (mini-take mic on), `corr-stop`→transcript,
`corr-cancel`→`ok`, `accept <text>`→`ok` (refocus target + paste), `editor-cancel`→`ok`,
`edit <text>`→`ok` (debug: open the editor on text, no mic). Standalone:
`dictate editor "слова"` runs the editor alone (stubbed mini-take). Socket
`/tmp/dictate.sock` (override `$DICTATE_SOCK` to run a test daemon off the live one) ·
state file `/tmp/dictate.recording` · logs `/tmp/dictate.log`, `/tmp/dictate-editor.log`.

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
- **StreamingSession**: energy-VAD segments the 16 kHz mono stream at pauses; a
  **single worker thread** runs `whisper_full` per closed segment and appends text
  in order — that's the streaming win: most of the audio is already transcribed by the
  time you stop, so `finish()` only has the open tail left (it flushes that segment,
  drains the worker, joins parts). If the energy VAD heard nothing it falls back to one
  pass over the full buffer. **No live interim text**: the worker just builds `parts_`;
  the banner is status-only and the take's words surface in the post-take editor, not
  live. (The old open-segment live-preview path was removed — see gotcha #12.)
- **Recorder** (`AVAudioEngine`): tap converts the hardware format → 16 kHz mono
  via `AVAudioConverter` (drained in a loop — a sample-rate conversion may not consume all
  input in one `convertToBuffer:`), sets `sess->live`, and calls `sess->feed`. It observes
  `AVAudioEngineConfigurationChangeNotification` and **rebuilds the tap + converter** on a
  device/route change (unplugging AirPods, switching input) — otherwise the engine stops
  and the take silently dribbles to an empty transcript.
- **whisper's built-in Silero VAD** is enabled in `make_params` on top of all
  that — it trims silence *inside* each segment (see gotcha #3).
- **Native UI** (`DictateController`, the `NSApp` delegate): owns the global ⌘⇧D
  hotkey (Carbon `RegisterEventHotKey`, keycode 2) + scoped Esc-cancel, the floating
  banner (`NSPanel`), auto-paste (synthetic ⌘V via `CGEvent`), and the menubar
  `NSStatusItem` + 60 s auto-stop timer — all on the main thread.

## Voice editor (post-take correction)

After a take the daemon opens a **foreground editor** instead of pasting directly
(`dictate editor` — one binary, a mode alongside `daemon`). **Why a separate
process:** a dedicated **KEY** window composites reliably and gets keyDown — unlike the
background accessory banner, whose live repaint the WindowServer throttles during a take
(post-mortem: the `banner-live-paint-unsolved` project memory). The editor
is an **accessory app** (`NSApplicationActivationPolicyAccessory`) whose window is a
**non-activating `NSPanel`** (`NSWindowStyleMaskNonactivatingPanel`): it takes keyboard
focus WITHOUT activating the app, so it surfaces on the user's *current* Space. (It was
briefly `Regular` + activating, but that activation yanked the user to the main Space —
gotcha #20.) So correction happens in the editor; the banner
only shows warm-up + recording status during the take. (The two-model live-preview +
`dictate ui` isolation explored during that saga are **stashed**, not in this build —
the editor supersedes live-preview-during-take.)

- **`EditorView`** (in `dictate.mm`): tokenizes the transcript into words + gaps; the
  cursor is ON a word (highlighted) or IN a gap (a «] [» caret). ←/→ step words+gaps,
  ↑/↓ jump to the nearest word a line up/down (the view owns its own wrapped layout, so
  the same geometry drives drawing + line nav). ⏎ or ⌘⇧D accept, Esc cancels. The word
  body is **clipped to the region between the header and the footer legend and scrolls
  vertically**: navigation/insert auto-scrolls minimally to keep the cursor line on-screen
  (`_followCaret`), the scroll wheel scrolls freely, and a faint right-margin knob shows
  position — so a long transcript can't overrun the legend or the window edge. The pure
  clamp/cursor-follow arithmetic is `ed_scroll_clamp` (`src/dictate_edscroll.h`, unit-tested);
  the editor window is sized to a screen-fraction (taller than the old fixed 460 px).
- **Uncertain-word highlight (whisper logprob)**: words whose min per-token confidence
  is below `ED_CONF_THRESHOLD` (0.60) are drawn amber (`ed_conf_color`), leading the eye
  to likely errors. whisper's per-token `p` (`whisper_full_get_token_p`) is pulled in
  `run_whisper_tok`, mapped tokens→words by `conf::words_confidence` (min-prob over each
  word's bytes; `src/dictate_conf.h`, unit-tested), assembled per-word in `finish()`,
  then carried daemon→editor over the `--conf` argv (serialized ints). It is **re-aligned onto
  the post-`finalize_transcript` tokenization** (`conf::realign`) since normalize re-cases
  words / rewrites punctuation; a count drift disables the highlight (never mis-paints).
  Voice-corrected/inserted words become confident (`EM_CONF_SURE`). Threshold + colour are
  editor constants atop the editor section in `src/dictate.mm`.
- **Mini-take (voice edit)**: SPACE on a word / in a gap → editor sends `corr-start`
  (daemon mic on), the window goes static + red 🎙; SPACE again → `corr-stop` → daemon
  transcribes → editor replaces the word / inserts at the gap (async, «расшифровка…»).
  Esc mid-take → `corr-cancel` (cancels just the take). A standalone `dictate editor`
  run (no `--from-daemon`) uses a local stub instead of the daemon mic.
- **Mini-take cleanup (`EditModel::applyMiniTake`, `src/dictate_editmodel.h`)**: whisper
  transcribes a single dictated word as a standalone sentence — Capital + trailing period
  («слово» → "Слово.") — which is wrong for a one-word correction. So the mini-take result
  is cleaned before splicing (NOT via `normalize_text`, which is take-boundary-only and would
  over-capitalize): (a) drop the spurious trailing sentence dot; (b) re-case the first letter
  to context — on a word **replace** it inherits the replaced word's case (keeps proper nouns /
  sentence starts capital, mid-sentence fixes lowercase), at a **gap** insert it Capitalizes
  only at a sentence start (`atSentenceStart`); (c) **spoken punctuation**: if the whole
  utterance names a mark (`em_spoken_punct` — «знак вопроса»→`?`, «точка»→`.`, «запятая»→`,`,
  «тире»→`—`, «открыть скобку»→`(`, «закрыть кавычки»→`»`, …) it inserts that symbol instead
  of the literal words. All pure + unit-tested. The plain `applyResult` (stub / text-only
  path) stays verbatim — only the voice path runs the cleanup.
- **Accept → paste**: the daemon saves the frontmost app at take start (`g_target_app`,
  `NSWorkspace`); on `accept <text>` it re-activates that app (`activateWithOptions:`
  `NSApplicationActivateAllWindows` — `Ignoring*` is a no-op on macOS 14+) and
  `paste_text`s after a short delay. Cancel → `editor-cancel` (refocus, no paste).
- **⌘⇧D routing**: the daemon **unregisters its global ⌘⇧D** while the editor is open
  (so the key reaches the editor's key window) and re-registers on accept/cancel/exit.
  A `waitpid` watcher recovers (re-register ⌘⇧D, clear `g_editor_open`, reap the child)
  if the editor dies without accept/cancel — see gotcha #15.

## CRITICAL GOTCHAS (hard-won — read before changing things)

1. **ggml backends load at runtime from `libexec`.** Homebrew ships the CPU/Metal
   backends as separate `.so` plugins in `$(brew --prefix ggml)/libexec`. You MUST
   call `ggml_backend_load_all_from_path(GGML_LIBEXEC)` **before** `whisper_init`,
   or it aborts: `devices=0 … GGML_ASSERT(device) failed` in `ggml_backend_dev_init`.
   The path is baked from the Makefile (version-independent via the `opt/ggml`
   symlink); override with `$DICTATE_GGML_BACKENDS`.

2. **Microphone is TCC-gated and inherits the launcher's grant.** A CLI gets the
   mic permission of whoever launched it. The launchd daemon therefore needs its
   OWN grant: approve the prompt on first `⌘⇧D`, or System Settings → Privacy &
   Security → Microphone → enable `dictate`. (The binary embeds
   `NSMicrophoneUsageDescription` via `src/Info.plist` — gotcha #16 — so the prompt shows
   a reason instead of a blank/suppressed dialog.) NB: pre-granting by running from a
   terminal does NOT help once the **launchd** daemon is the process actually
   calling the mic — the mic call happens in that process, attributed to it. Empty
   transcripts almost always = missing mic permission. **Auto-paste additionally
   needs an Accessibility grant** (System Settings → Privacy & Security →
   Accessibility → enable `dictate`) to synthesize ⌘V; the daemon prompts for it once
   at startup. Without it the transcript still lands on the clipboard and the banner
   says «готово — вставь ⌘V» (graceful degrade) — nothing breaks.

3. **Silence hallucination «Продолжение следует…».** whisper invents this phrase on
   silence/low noise. `suppress_nst` alone does NOT stop it. The fix (and what the
   old bash script relied on) is whisper's built-in **Silero VAD**:
   `wp.vad=true; wp.vad_model_path=<ggml-silero-v5.1.2.bin>`. Enabled by default if
   the model exists; disable with `WHISPER_VAD=0`, point elsewhere with
   `WHISPER_VAD_MODEL`. Reproducing offline needs REAL noise (a mic tail or
   `anoisesrc`), not `anullsrc` zeros.

4. **Clipboard via `NSPasteboard` is UTF-8-native** — Cyrillic round-trips cleanly.
   Do not "fix" this by shelling out to `pbcopy`: that path mangled Cyrillic to
   Mac-Roman mojibake under a C / `LANG=ru` locale (the bug that killed the bash
   version). Stay on NSPasteboard. Auto-paste (`paste_text`) sets the clipboard,
   synthesizes ⌘V, then restores the prior clipboard after a fixed **0.4 s** (a
   generation token cancels a stale restore if a newer paste lands first). Two known
   limits of paste-by-clipboard, both inherited from the old Hammerspoon flow and
   accepted: a clipboard manager can capture the transcript during that ~0.4 s
   window, and under heavy load the restore could fire before the paste lands.

5. **`whisper_context` is NOT thread-safe.** Exactly one worker thread touches
   `g_ctx`, and takes are sequential. The hotkey/timer stop runs `finish()` on a
   **detached thread** (so the run loop never freezes), which means a new take could
   otherwise start while the previous take's worker is still decoding → two
   `whisper_full` on one context. The **`g_finishing`** flag prevents this: set under
   `g_mu` in `daemon_stop_detach` (atomic with the `g_sess` move-out), checked in
   `daemon_start`/`daemon_feedfile`, cleared in `stopFinishedWithText`. Only this one
   worker ever calls `whisper_full` — do not add a second concurrent `whisper_full` on
   the same context.

6. **The audio tap runs on a realtime thread.** `feed()` must stay cheap (VAD math
   + enqueue). Heavy work (whisper) belongs on the worker. Blocking the tap drops
   audio. `feed()`/`processFrame` only does the VAD RMS + segment buffering + an
   enqueue (a `std::move` of the closed segment under `qmu_`) — no decode, no
   allocation on the steady-state path. ALL tap-path buffers are pre-`reserve`d:
   `full_`/`pending_`, AND `cur_`/`preroll_`; on segment close `rotateSegment` swaps
   in a buffer from a worker-recycled pool (`recycle_`, guarded by `qmu_`) instead of
   re-growing `cur_`, and the `Recorder` tap reuses one `AVAudioPCMBuffer` (`convOut`)
   across callbacks — so a closed segment costs no heap allocation on the realtime thread.

7. **Resident model = ~573 MB Metal while the daemon runs — by default.** Intentional
   (that's the speed win): the memory is not a leak. Opt OUT with **idle-unload**:
   `DICTATE_IDLE_UNLOAD_SEC=N` frees `g_ctx` (`whisper_free`) after N s with no take, and
   the next take **reloads on demand** (`ensure_model_loaded`, ~600 ms–1 s, paid once on
   the calling/main thread). Default OFF (unset / `<=0` → stays resident — the speed
   trade-off is the user's to make). The free runs on MAIN under `g_mu` and only when
   `g_sess==null && !g_finishing && !g_editor_open`, so it can never race the lone whisper
   worker (gotcha #5). Pure gate: `src/dictate_idle.h` (unit-tested — gotcha #19); driver:
   `DictateController setupIdleTimer`/`idleTick`. Backends (gotcha #1) load once and are
   never freed; only the model context cycles.

8. **Rebuilding does NOT update a running daemon.** It's resident in memory, and the
   LaunchAgent runs the **installed copy** (`~/.local/bin/dictate`), not the repo
   build. After `make`: `cp dictate ~/.local/bin/dictate` then
   `launchctl kickstart -k gui/$(id -u)/com.user.dictate` (or `dictate quit` if not
   under launchd; KeepAlive respawns it). See gotcha #13.

9. **Daemon doesn't answer `ping` during model load** (~600 ms): the accept loop
   starts after the model is loaded (the socket is bound first, so connects queue).
   `ensure_daemon` already retry-polls; don't treat a brief non-answer as failure.

10. **Streaming only helps with pauses.** Segments close on ~700 ms of silence and
    are transcribed during recording, so `stop` finalizes just the tail. A short or
    pauseless clip becomes one segment → effectively single-pass (still fast).

11. **Do NOT shrink `wp.audio_ctx` to the segment length.** It's the obvious "speed
    up the encoder on short segments" idea (encoder cost scales with audio_ctx, default
    1500 ≈ 30 s) and it *is* faster — but the large-v3-turbo model is trained on the
    full 30 s positional range, so a small audio_ctx pushes it off-distribution and it
    **loops/hallucinates** (measured: a 3 s clip degraded into «Привет! Привет!…»; a
    19 s clip happened to survive). Segment lengths vary, so this fails intermittently
    on real speech → unusable. Flash attention (gotcha-free, ~20%) is the safe win.

12. **Open-segment live preview — REMOVED (was the trickiest concurrency in the codebase).**
    It once decoded the still-open segment in the worker's idle gaps to show words *before*
    the pause, streaming them into the banner. It was removed when the banner became
    status-only (the post-take editor is where you read/correct the transcript, so a live
    tail earned nothing but the WindowServer-throttled jitter and a wasted ~450 ms decode
    loop). Gone with it: the `InterimCb`/`cb_` callback, the tap's snapshot publish
    (`previewBuf_`/`pmu_`/`workSnap_`/`inSpeechPub_`), `maybePreview`, the `PREVIEW_*`
    constants, and the `--interim`/`--realtime` flags. **What stayed** is the real
    streaming: the worker still decodes each *closed* segment into `parts_` during
    recording (the latency win — gotcha #5/#6). Lesson if you ever re-add a live tail: it
    needs a 2nd decode on the one worker — keep the tap to a memcpy-only publish (gotcha #6),
    decode at **full `audio_ctx`** (gotcha #11), let real segments preempt it, and keep its
    text display-only (never into `parts_`). Background: the `banner-live-paint-unsolved` memory.

13. **The LaunchAgent binary must NOT live in `~/Documents` (nor `~/Desktop` /
    `~/Downloads`).** Those are TCC-protected, and a **launchd-spawned** process hangs
    in dyld (`__open` → `getOnDiskBinarySliceOffset`) just trying to *open* a binary
    there: it produces no log output and never binds the socket, while
    `launchctl print` cheerfully reports it `state = running`. The same binary run
    from a Terminal works (it inherits the shell/Terminal's Documents grant), which
    makes this look like a launchd-only ghost. Fix: install to `~/.local/bin/dictate`
    and point the plist there. Related: on **macOS 14+ use `launchctl bootstrap` /
    `bootout` / `kickstart -k`** — the legacy `load -w` / `unload` are deprecated and on
    macOS 26 leave wedged/zombie jobs (0 fds, unreapable) that never rebind.

14. **Ad-hoc signing breaks TCC grants on every rebuild.** A plain `make` binary is
    `adhoc, linker-signed`, so its TCC identity is its **cdhash** — which changes each
    build. So the Microphone / Accessibility grants you give evaporate on the next
    `make` (symptom: auto-paste silently stops; `printf 'axcheck\n' | nc -U
    /tmp/dictate.sock` → `untrusted`; `grep paste: /tmp/dictate.log` shows
    `ax_trusted=0`). Fix: a **stable self-signed identity** — run
    `scripts/make-codesign-cert.sh` once; the Makefile then signs `dictate` with
    `--identifier com.user.dictate --sign dictate-codesign`, making the designated
    requirement cert-based (`identifier "com.user.dictate" and certificate leaf =
    H"…"`), stable across rebuilds. Grant Mic + Accessibility ONCE to the signed
    `~/.local/bin/dictate` and they persist. Switching an already-granted ad-hoc binary
    to the signed identity changes the DR, so you re-grant once at the switch. (The
    self-signed cert shows `CSSMERR_TP_NOT_TRUSTED` in `find-identity` — that's fine;
    trust matters for *verification*, not for *signing* or local execution.)

15. **The editor is a separate process (accessory + non-activating panel — gotcha #20);
    the daemon hands it ⌘⇧D by UNREGISTERING the global hotkey while it's open.** Four
    hard-won pieces: (a) a
    borderless window needs `-canBecomeKeyWindow`→YES *and* its setup in
    `applicationDidFinishLaunching:` (NOT inline before `[NSApp run]`) or it never
    becomes key and keyDown is lost; (b) Cmd-chords arrive via `performKeyEquivalent:`,
    NOT `keyDown:`; (c) if the editor dies without sending `accept`/`editor-cancel`
    (crash, ⌘Q) the daemon must re-register ⌘⇧D + clear `g_editor_open` via a `waitpid`
    watcher (which also reaps the child), else it wedges — no more takes; (d) socket
    `stop` must NOT spawn the editor (only the hotkey/timer path does, via
    `stopFinishedWithText`/`openEditorWithText:`) — else scripted `dictate stop` pops a
    GUI *and* its socket reply stalls. See the **Voice editor** section.

16. **The embedded `Info.plist` must live in `src/`, NOT next to the built binary.** The
    binary carries its own `Info.plist` (so TCC has `NSMicrophoneUsageDescription` and a
    `CFBundleIdentifier` matching the signing identifier) baked in at link time via
    `-sectcreate __TEXT __info_plist src/Info.plist` (Makefile). Keep that file under
    `src/`: if an `Info.plist` sits **adjacent** to `./dictate`, `codesign` decides the
    directory is a **bundle** — `codesign -dv` reports `Format=bundle` and it writes a
    `_CodeSignature/CodeResources` sidecar. That sidecar is NOT copied by `cp dictate
    ~/.local/bin/dictate`, so the installed binary's signature breaks → Mic/Accessibility
    grants evaporate (a gotcha-#14 failure, but sneakier: the repo build verifies fine).
    With the plist in `src/`, `codesign -dv` shows `Format=Mach-O thin` and the signature
    rides inside the Mach-O, so `cp` preserves it. Verify after a build:
    `codesign -dv dictate 2>&1 | grep Format` must say `Mach-O thin`, and there must be NO
    `_CodeSignature/` directory in the repo.

17. **The daemon socket is owner-only + peer-authenticated; `feedfile`/`--file` open
    non-blocking.** `/tmp/dictate.sock` is created under `umask(0077)` + `chmod 0600`, and
    `serve_client` rejects any peer whose euid ≠ the daemon's (`getpeereid`) **before
    reading a byte** — the `accept <text>` verb synthesizes a ⌘V paste into the frontmost
    app, so an unauthenticated peer would be a keystroke-injection sink. Testing
    consequence: a client running as a *different* user is silently dropped; same-user
    `nc -U` / `dictate` clients work as before. The single-threaded accept loop sets
    `SO_RCVTIMEO` (5 s) so a peer that connects and dribbles a partial line can't stall
    all socket traffic. And `load_wav_pcm16` opens `O_RDONLY|O_NONBLOCK` then requires
    `S_ISREG`: a FIFO/device path returns `wav read failed` instead of **hanging the
    daemon in `open()`** (the bare `fopen` did hang — the `fstat` check alone is too late,
    the open itself blocks on a writer-less FIFO).

18. **One take is hard-capped at `MAX_TAKE_SEC` (120 s) inside `StreamingSession::feed`.**
    The cap bounds memory on EVERY entry path — mic, socket `start`, editor mini-take —
    not just the 60 s GUI auto-stop timer (which doesn't cover socket-/editor-started
    takes, so an abandoned mini-take would otherwise grow the buffer forever). Side effect
    on the offline paths: a `--file` / `feedfile` clip longer than 120 s is **truncated**
    at the cap (a `⚠ … truncated` line is printed — not silent). For full-length offline
    A/B use `--once`: the single-pass path runs `whisper_full` on the whole buffer and is
    NOT capped. `full_` is `reserve()`d to exactly the cap, so the realtime tap still never
    reallocates (gotcha #6).

19. **`make test` covers the EXTRACTED pure logic, NOT the `dictate.mm` macOS build.** The
    unit-testable logic was factored out of `dictate.mm` into `src/dictate_*.h` (header-only,
    `inline`; `dictate.mm` `#include`s them so there is ONE definition — change a header and
    both the app and the tests see it). `make test` builds `tests/*.cpp` + those headers with
    the host `c++` (clang++ on macOS, g++ on Linux) and links NOTHING macOS-specific (no
    whisper/ggml/AppKit/AVFoundation/Accelerate) — the `test` goal even skips the brew
    resolution. So `make test` runs anywhere and is the fast inner loop for the parser/VAD/
    editor/auth logic. **It does NOT compile `dictate.mm`.** A change that only touches a
    header is validated by `make test`; a change that touches the `.mm` (or a header's
    signature used by the `.mm`) STILL needs `make` + `make tsan|asan` on a Mac to confirm
    the Objective-C++ side compiles/links. Consequence when editing off a Mac (e.g. Linux):
    you can prove the pure logic but NOT the macOS build — say so, don't claim the app builds.
    What stays e2e-only (needs the model / a live socket / AppKit): the streaming
    segment *decode* + `finish()`/single-pass fallback, the live socket peer-auth +
    `SO_RCVTIMEO`, `paste_text`'s actual ⌘V, the banner. Those keep `--file`/`feedfile`/tsan/asan
    as their coverage (run tsan/asan over `--file` to exercise the tap↔worker concurrency).

20. **The editor window must be an *accessory* app + a *non-activating* `NSPanel`, or it
    opens on the main Space.** Symptom: trigger ⌘⇧D (or run `dictate editor`) from a
    non-main Mission-Control Space and the screen yanks to the **main** Space with the
    editor there. Cause: the editor was a `NSApplicationActivationPolicyRegular` app that
    called `activateIgnoringOtherApps:` — activating a Regular app switches the user to the
    process's "home" Space (main). It is **NOT** a window-`collectionBehavior` problem
    (`MoveToActiveSpace`, then `CanJoinAllSpaces|FullScreenAuxiliary`, both had ZERO effect)
    and **NOT** launchd-specific (a Terminal-launched `dictate editor` jumped too — so it's
    the activation, not the daemon spawn). Fix = the Spotlight/Raycast palette trick:
    `setActivationPolicy:Accessory`, make the window an `NSPanel` with
    `NSWindowStyleMaskNonactivatingPanel` (becomes KEY + gets keyDown WITHOUT activating),
    `hidesOnDeactivate=NO` (a panel hides on deactivate by default and we never activate),
    keep `CanJoinAllSpaces|FullScreenAuxiliary`, and **never call `activate*`**. This is
    exactly what the (working) banner already does. Don't "restore" the Regular+activate
    design — it reads cleaner but reintroduces the bug.

21. **`initial_prompt` (user-dictionary lexical bias) must stay SHORT, and its backing
    storage must outlive every `whisper_full` call.** Two hard-won points: (a) the turbo
    model is prompt-sensitive (same family as gotcha #11) — a long or sentence-like prompt
    makes it loop/hallucinate, so the dictionary is assembled as a SHORT, token-budgeted,
    comma-separated VOCAB LIST (not prose), capped at a conservative estimate of
    `n_text_ctx/2 = 224` prompt tokens (`dict::DEFAULT_MAX_TOKENS`; tune down with
    `WHISPER_PROMPT_MAXTOK` if you ever see looping). The token estimate deliberately
    over-counts: we CANNOT run whisper's BPE tokenizer before the model loads, so the prompt
    is built in pure code (`src/dictate_dict.h`, unit-tested — gotcha #19) and leans high so
    the real token count stays under the cap. (b) `whisper_full_params.initial_prompt` is a
    NON-OWNING `const char*`. It points at the process-lifetime global `g_initial_prompt`
    (built once at startup in `main`, never reassigned after the worker threads start), so the
    pointer stays valid across the worker / single-pass decodes — do
    NOT point it at a temporary. Default ON if `~/.config/whisper/dictionary.txt` exists;
    `WHISPER_PROMPT=0` disables; `WHISPER_DICT` overrides the path. Measure WER before/after
    with `scripts/bench-wer.py` (it drives the real binary, so Mac-only — gotcha #19).

## Native UI (in-process — Hammerspoon dropped)

The daemon is fully self-contained; `DictateController` (the `NSApp` delegate) owns
all UI on the **main thread**:

- **Hotkey**: `RegisterEventHotKey(kVK_ANSI_D=2, ⌘⇧)` toggles a take — keycode 2 is
  the physical D key, so it survives a Cyrillic layout (and needs no Accessibility).
  A second hotkey for **Esc** is registered only for the duration of a take (so Esc
  stays normal everywhere else) and cancels it.
- **Banner**: a borderless floating `NSPanel` whose content view is a **flat
  translucent fill** (layer-backed `NSView`, black α`BANNER_BG_ALPHA` — Hammerspoon-
  style glass, no blur) + a hairline border, holding one centred `NSTextField`. Spans
  the **full screen width** (`BANNER_HMARGIN` edge gaps), a touch above mid-screen;
  **height auto-grows** with the text from a **fixed top edge**, capped at
  `BANNER_MAXH_FRAC` of the screen. It is **status-only** — it never shows live
  transcript text (the take's words go to the post-take editor); the header is short
  and stable, so it does not jump. Ignores mouse. One attributed string layers bright
  title / dim subtitle — all **explicit** colours (no vibrant backdrop now, so a
  semantic colour like `secondaryLabelColor` would vanish in Light Mode). States:
  «Запуск микрофона…» (warm-up, gated on `g_sess->live` via a 0.1 s poll) → «🎙 говори»
  (static, no live text) → «расшифровка…» → hidden. Updated only
  on the main queue. A `_gen` counter keeps a stale timed auto-hide from hiding a newer
  take's banner. All look/layout knobs are the `BANNER_*` constants atop `src/dictate.mm`.
- **Auto-paste**: `paste_text` — clipboard + synthetic ⌘V (`CGEventPost`), restore
  after 0.4 s; degrades to clipboard-only if not Accessibility-trusted (gotchas #2/#4).
- **Menubar**: `NSStatusItem` (⏳ idle / 🎙 m:ss recording, click toggles) + a 1 Hz
  `NSTimer` that enforces the 60 s cap.

The Unix socket + client verbs stay (scripts/tests). `/tmp/dictate.recording` is
still touched while capture is live — a cheap external flag; nothing reads it now
that Hammerspoon is gone. `~/.hammerspoon/init.lua` no longer references dictate (its
dictate block was removed, `clip2vps` kept); the prior version is archived at
`~/.hammerspoon/init.lua.pre-dictate-removal.bak`.

## Daemon lifecycle (LaunchAgent)

Auto-starts at login as a **user LaunchAgent** (`com.user.dictate`, RunAtLoad +
KeepAlive). It must be a user agent, not a system LaunchDaemon — it needs the user's
mic, clipboard, and GUI session. The plist runs the **installed copy at
`~/.local/bin/dictate`**, not the repo build (gotcha #13).

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
  `WHISPER_LANG` (default `ru`), `WHISPER_VAD_MODEL`, `WHISPER_VAD=0` to disable
  VAD, `DICTATE_GGML_BACKENDS` to override the backend dir, `DICTATE_SOCK` to override
  the socket path (run a test daemon off the live one).
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
- `DICTATE_IDLE_UNLOAD_SEC=N` (default OFF / `0`) — free the ~573 MB resident model after
  N seconds with no take, reloading on demand on the next take (~600 ms–1 s). Trades the
  resident-speed win for memory when idle (gotcha #7). The idle gate (`src/dictate_idle.h`,
  unit-tested — gotcha #19) is polled by an `NSTimer` at `idle_poll_interval_sec(N)`
  (timeout/3, clamped to 1–10 s).
- VAD/segmentation constants in `src/dictate_vad.h` (with the pure `Segmenter`):
  `SILENCE_CLOSE_FR` (~700 ms pause closes a segment), `SPEECH_FACTOR`/`ABS_FLOOR`
  (sensitivity), `MAX_SEG_FR` (~20 s hard cap), `PREROLL_FR` (~300 ms kept before onset),
  `SPEECH_CONFIRM_FR`, `FRAME`. The Silero VAD params live in `make_params`
  (`min_silence_duration_ms`, `speech_pad_ms`).

## whisper.cpp notes (Homebrew 1.8.6)

API used: `whisper_init_from_file_with_params` (+ `whisper_context_default_params`,
`use_gpu=true`), `whisper_full_default_params(WHISPER_SAMPLING_GREEDY)`,
`whisper_full`, `whisper_full_n_segments`, `whisper_full_get_segment_text`,
`whisper_free`. VAD via `whisper_full_params.{vad,vad_model_path,vad_params}` +
`whisper_vad_default_params`. Lexical bias via `whisper_full_params.initial_prompt` (a
non-owning `const char*`, backed by the `g_initial_prompt` global — gotcha #21). Headers:
`$(brew --prefix whisper-cpp)/include`;
`ggml.h` from `$(brew --prefix ggml)/include`.

## Status / roadmap

Done: resident model · daemon+client over Unix socket · streaming (VAD-segmented) ·
Silero VAD (silence-hallucination fix) · NSPasteboard clipboard · LaunchAgent
autostart · `--file`/`feedfile` test paths · Metal flash attention (~20% faster) ·
perf-core thread default · vectorized (Accelerate) VAD RMS · self-contained native hotkey + banner + auto-paste + menubar —
Hammerspoon dropped · **post-take voice-editor: navigate (←/→ ↑/↓) + voice-edit
(replace/insert via mini-takes) + accept→focus-restore→paste** · **unit tests (doctest,
`make test`): pure logic factored into `src/dictate_*.h` — WAV parse, VAD/segmentation +
cap, editor model, socket parse, peer-auth, paste-gen — host-portable, gotcha #19** ·
**user-dictionary lexical bias → whisper `initial_prompt` (token-budgeted, env-toggled;
`src/dictate_dict.h` + `scripts/bench-wer.py` WER harness — gotcha #21)** ·
**post-normalization of the final transcript (`normalize_text`: capitalization/punctuation/
typography, `DICTATE_NORMALIZE`; applied at the take boundary, not inside `finish()`)** ·
**uncertain-word highlight in the editor (whisper per-token logprob → per-word min
confidence → amber below `ED_CONF_THRESHOLD`; `src/dictate_conf.h` incl. `realign` across
`normalize_text`, unit-tested — see the Voice-editor section)** ·
**idle-unload: free the resident model after `DICTATE_IDLE_UNLOAD_SEC` idle, reload on
demand — opt-in, off by default; `src/dictate_idle.h` + `idleTick` under `g_mu`, gotcha #7** ·
**status-only banner: no live transcript in the banner (it jumped/grew as words streamed) —
the take's words appear in the post-take editor. The open-segment live-preview machinery
(callback, tap snapshot, `maybePreview`, `PREVIEW_*`, `--interim`/`--realtime`) was removed
entirely; per-segment streaming into `parts_` stays (the latency win) — gotcha #12**.

Declined: warm-mic option (pre-open device to kill the ~0.5–1.5 s avfoundation warm-up) —
deliberately not pursued; don't re-propose.

Editor follow-ups (minor, not blocking): make editor-after-every-take optional if it feels
heavy; `relayout` re-measures on every `drawRect` (cheap at current word counts). (The in-take
banner live-preview is gone entirely now — the banner is status-only.)
