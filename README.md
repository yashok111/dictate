# dictate

A small native macOS dictation tool in Objective-C++, with **streaming**
transcription. Hold **⌘⇧D**, speak, press again to stop — it captures the microphone
with **AVFoundation**, transcribes locally with **whisper.cpp** (libwhisper, Metal
GPU), shows a **status banner** while you talk, then opens a **post-take voice editor**
to review and fix the transcript (by voice or keyboard) and, on accept, **pastes** it
into the app you were in. Fully self-contained: it owns the hotkey, banner, editor,
paste, and a menubar indicator **natively** — no Hammerspoon, no shell script.

## Why native + a daemon

- **Resident model.** A long-running **daemon** loads the model once (~547 MB on disk,
  ~573 MB resident in Metal) and keeps it in GPU memory. The old shell pipeline relaunched
  `whisper-cli` on every take, paying ~1.5–2 s to reload the model each time.
- **Streaming.** Because one process spans the whole take, audio is transcribed
  *while you speak*: an energy-VAD segments the stream at natural pauses and a
  worker thread transcribes each segment as it closes. On **stop** only the
  trailing segment is left to finish, so stop returns almost immediately.
- **Clean clipboard.** `NSPasteboard` is UTF-8-native — the Mac-Roman mojibake the
  `pbcopy` path could produce is impossible here.

## Architecture

Normally you just press **⌘⇧D** — the daemon (a login LaunchAgent) owns the global
hotkey, the on-screen banner, auto-paste, and the menubar indicator. The CLI verbs
below are for scripting and testing:

```
dictate daemon         resident: model + mic + streaming engine, Unix socket server
dictate start          begin a take (auto-spawns the daemon if needed)
dictate stop           finalize → prints transcript to stdout (also → clipboard)
dictate cancel         discard the current take
dictate ping           "pong" if a daemon is alive
dictate quit           stop the daemon

dictate --file a.wav          one-shot, no daemon: stream a 16 kHz mono WAV
dictate --file a.wav --once   one-shot, single-pass (A/B comparison)
```

Socket: `/tmp/dictate.sock` · state file (capture-is-live): `/tmp/dictate.recording`
· daemon log: `/tmp/dictate.log`.

## Build

Requires Xcode Command Line Tools and Homebrew `whisper-cpp` (pulls in `ggml`):

```sh
brew install whisper-cpp
make
```

Model path defaults to `~/.config/whisper/ggml-large-v3-turbo-q5_0.bin`
(override with `$WHISPER_MODEL` / `--model`; language `$WHISPER_LANG` / `--lang`,
default `ru`).

### Tests

```sh
make test     # unit tests (doctest) for the pure logic — no mic/GPU/whisper needed
```

`make test` covers the platform-independent pieces factored into `src/dictate_*.h`
(WAV parsing, the energy-VAD/segmentation state machine and take cap, the voice-editor
cursor/tokenization model, socket command parsing, peer-auth and paste-generation checks,
and the user-dictionary → `initial_prompt` builder).
It links nothing macOS-specific, so it builds and runs with any C++17 compiler (clang++ or
g++) — it does not compile the full `dictate.mm` app. The model/mic/UI paths stay covered by
the `--file` / `feedfile` integration runs and the `make tsan` / `make asan` sanitizer builds.

## Microphone permission (read this)

A CLI tool inherits the **TCC microphone grant of whatever launched it**. The
reliable way to give the daemon mic access:

1. **Run the daemon once from your terminal** (iTerm2 already has mic access):
   ```sh
   ~/Documents/dictate/dictate daemon
   ```
   Approve the mic prompt if macOS shows one. Leave it running. Now ⌘⇧D (or
   `dictate start`) connects to this already-running daemon and records fine.

2. **For permanence**, install the LaunchAgent so the daemon starts at login. Install
   the binary **outside `~/Documents`** — that folder is TCC-protected and a launchd
   agent hangs trying to open a binary there (it'd silently never start):
   ```sh
   mkdir -p ~/.local/bin && cp dictate ~/.local/bin/dictate   # NOT ~/Documents
   # launchd doesn't expand ~, so bake your real home into the installed plist:
   sed "s|/Users/YOUR_USERNAME|$HOME|" com.user.dictate.plist > ~/Library/LaunchAgents/com.user.dictate.plist
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.user.dictate.plist
   ```
   On first mic use macOS prompts for the `dictate` binary; approve it under
   System Settings → Privacy & Security → Microphone. (Stop with
   `launchctl bootout gui/$(id -u)/com.user.dictate`; restart after a rebuild with
   `cp dictate ~/.local/bin/ && launchctl kickstart -k gui/$(id -u)/com.user.dictate`.)

> If a take comes back empty («пусто»), the daemon almost certainly lacks mic
> access — start it from a terminal as in step 1, or grant it in System Settings.

**Accessibility (for auto-paste).** To type the transcript into the focused app the
daemon synthesizes ⌘V, which needs an Accessibility grant. It prompts once at first
launch — approve `dictate` under System Settings → Privacy & Security → Accessibility.
Without it the transcript still lands on the clipboard and the banner says
«готово — вставь ⌘V»; just press ⌘V yourself.

**Make the grants survive rebuilds (recommended).** A plain build is ad-hoc-signed, so
macOS ties your Mic/Accessibility grants to the exact binary hash — every `make`
invalidates them and auto-paste silently stops. Run `scripts/make-codesign-cert.sh`
**once** to create a stable self-signed identity; `make` then signs the binary so the
grants persist. Diagnose a non-pasting take with
`printf 'axcheck\n' | nc -U /tmp/dictate.sock` (want `trusted`).

## Everyday use

Press **⌘⇧D** to start, speak, press **⌘⇧D** again to stop. While you talk the banner
shows **status only** (mic warm-up → recording → transcribing). On stop the **voice
editor** opens with the transcript for review; **⏎** (or **⌘⇧D**) accepts and pastes it
into the app you were in, **Esc** cancels. The menubar 🎙 shows the elapsed time; a take
auto-stops at 60 s. (See [Voice editor](#voice-editor-review--fix-after-each-take) below.)

The CLI still works for scripting/testing — note that `dictate stop` is the scripting
path: it prints/copies the transcript and does **not** open the editor:

```sh
dictate start      # speak…
dictate stop       # prints the transcript, copies it to the clipboard (no editor, no paste)
```

### Make a test clip without a mic

```sh
say -v Milena -o /tmp/t.aiff "Привет, это тест распознавания"
ffmpeg -i /tmp/t.aiff -ar 16000 -ac 1 -y /tmp/t.wav
./dictate --file /tmp/t.wav            # streaming
./dictate --file /tmp/t.wav --once     # single-pass, for comparison
```

## Voice editor (review & fix after each take)

After a take the transcript opens in a small floating editor instead of being pasted
blindly — so you can catch whisper's mistakes before they land:

- **Navigate** word by word with **←/→** (it steps through words and the gaps between
  them) and jump lines with **↑/↓**.
- **Fix a word by voice**: press **SPACE** on a word (or in a gap) to start a mini-take,
  speak the correction, **SPACE** again to apply it — the word is replaced, or new text is
  inserted at the gap. **Esc** during a mini-take cancels just that edit.
- **Corrections match the surrounding case.** A single dictated word comes back from whisper
  as a mini-sentence (Capitalized, with a trailing period); the editor strips that and
  re-cases the word to its context — a mid-sentence fix stays lowercase, while a sentence
  start (or a replaced proper noun) keeps its capital. So fixing one word doesn't leave a
  stray «Слово.» in the middle of a line.
- **Insert punctuation by voice.** Say the *name* of a mark and the editor inserts the symbol
  instead of the words: «знак вопроса» → `?`, «точка» → `.`, «запятая» → `,`,
  «двоеточие» → `:`, «тире» → `—`, «многоточие» → `…`, «открыть/закрыть скобку» → `(` `)`,
  «открыть/закрыть кавычки» → `«` `»`. Handy for marks dictation won't reliably produce on
  its own — stand in the gap where you want it and dictate the name.
- **Delete** the current word (or the one before the cursor) with **⌫**, the next one with **⌦**.
- **Low-confidence words are highlighted** (amber): whisper's per-token probability is
  mapped to a per-word confidence, so the words most likely to be wrong draw your eye.
- **⏎** or **⌘⇧D** accepts — the editor closes, refocuses the app you were in, and pastes.
  **Esc** cancels the whole take (nothing is pasted).

The editor is a separate accessory window that takes keyboard focus without pulling you to
another Space, so it shows up wherever you're working.

## No Hammerspoon needed

The hotkey, banner, auto-paste, and menubar indicator are all native now —
Hammerspoon is no longer involved. The daemon registers ⌘⇧D itself (by the physical
D keycode, so it works on a Cyrillic layout too), shows its own banner gated on real
mic readiness, and pastes via a synthetic ⌘V. Earlier versions drove the UI from
`~/.hammerspoon/init.lua`; that integration has been removed.

## Transcript clean-up (post-normalization)

Whisper's raw output is tidied before it reaches the editor / clipboard / paste: the first
letter of each sentence is capitalized, stray spaces around punctuation are fixed, `...`
becomes `…`, and a spaced hyphen becomes an em-dash (` — `). It is deliberately
**conservative** — it leaves mixed RU/EN, domains (`github.com`), file names, version
numbers, and decimals (`3,14`) untouched. Set `DICTATE_NORMALIZE=0` to disable it and get
the raw whisper text (useful for an A/B). The transform itself is pure logic in
`src/dictate_text.h` (`normalize_text`) and is covered by `make test`.

## Tuning the streaming VAD

In `src/dictate_vad.h`: `SILENCE_CLOSE_FR` (pause length that closes a segment,
~700 ms), `SPEECH_FACTOR`/`ABS_FLOOR` (sensitivity), `MAX_SEG_FR` (hard cap per
segment, ~20 s), `PREROLL_FR` (audio kept before speech onset).

## Custom vocabulary (dictionary)

Bias whisper toward **your** words — names, tech terms, English spoken inside Russian —
without changing the model. Create `~/.config/whisper/dictionary.txt`, one word or short
phrase per line (order = priority, `#` starts a comment, blanks/duplicates ignored):

```
Kubernetes
gRPC
Курбатов
pull request
C#
```

The daemon reads it once at startup and feeds it to whisper as an `initial_prompt`. Keep it
**short and high-value** — a long, sentence-like list makes the turbo model loop, so it's
capped at ~224 prompt tokens and assembled as a plain comma-separated word list. Copy
`examples/dictionary.txt` as a starting point, then reload after editing:

```sh
launchctl kickstart -k gui/$(id -u)/com.user.dictate
```

Toggle and override with env vars (same spirit as `WHISPER_VAD` / `WHISPER_FLASH`):
`WHISPER_PROMPT=0` disables the dictionary, `WHISPER_DICT=/path/to/file` points elsewhere,
`WHISPER_PROMPT_MAXTOK=N` changes the token budget.

**Measure the gain.** `scripts/bench-wer.py` transcribes a folder of reference clips with
the dictionary off vs on and reports the word error rate (WER) before/after — so you can
confirm it actually helps and catch any prompt-induced looping (it drives the real binary,
so run it on the Mac):

```sh
# each foo.wav has a sibling foo.ref.txt holding the correct transcript
python3 scripts/bench-wer.py --clips bench/clips
```

## Freeing memory when idle

The daemon keeps the model resident (~573 MB of Metal memory) so every take is fast — no
per-take reload. If you'd rather reclaim that memory when you're not dictating, set
`DICTATE_IDLE_UNLOAD_SEC=N`: after `N` seconds with no take, the daemon frees the model, and
the **next** take reloads it on demand (a one-time ~0.5–1 s wait before that take starts).

```sh
# free the model after 5 minutes idle (set in the LaunchAgent plist's env, then reload)
DICTATE_IDLE_UNLOAD_SEC=300
```

Off by default — the resident model is the whole point of the daemon, so unloading is an
explicit memory-vs-latency trade-off you opt into.

## Roadmap

- [x] Resident model, mic capture, clipboard, file-mode for testing
- [x] Daemon + client over a Unix socket
- [x] Streaming (VAD-segmented, transcribe-while-speaking)
- [x] Self-contained native hotkey + status banner + auto-paste + menubar (Hammerspoon dropped)
- [x] Post-take voice editor — navigate (←/→ ↑/↓), fix words by voice, low-confidence (logprob) highlight, accept→paste
- [x] Unit tests (doctest, `make test`) for the pure logic factored into `src/dictate_*.h`
- [x] Custom-vocabulary dictionary → whisper `initial_prompt` (lexical bias, WER bench)
- [x] Post-normalization of the transcript (capitalization / punctuation / typography, `DICTATE_NORMALIZE`)
- [x] Unload the model when idle (`DICTATE_IDLE_UNLOAD_SEC`, reload on demand)
