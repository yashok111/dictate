# Voice editor (post-take correction) — `dictate editor`

Deep dive moved out of `CLAUDE.md`. Read this before touching `EditorView`, `EditModel`,
the mini-take protocol, confidence highlighting, or accept→paste.

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
  the same geometry drives drawing + line nav). ⏎ or ⌘⇧D accept, Esc cancels, ⌘Z/⌃Z
  undo and ⌘⇧Z/⌃⇧Z redo the last content edit (a mini-take splice or a delete — NOT
  navigation; restores words+cursor+confidence exactly). The two-stack `EditHistory`
  (pure in `src/dictate_editmodel.h`, unit-tested) holds pre-edit snapshots: each edit
  (`applyResult:`/`deleteCurrent:`) snapshots BEFORE mutating and `recordEdit`s only if the
  document actually changed (snapshot compare — no phantom undo on a same-text re-dictation),
  which also forks the redo stack; undo/redo park the current state on the opposite stack so
  the pair round-trips losslessly. The word
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
  then carried daemon→editor over the `--conf` argv (serialized ints — the transcript itself
  travels over the editor's **stdin** (`--stdin`), never argv: argv is `ps`-visible to every
  local user, and the dictated text is the one thing everything else here keeps private). It is **re-aligned onto
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
