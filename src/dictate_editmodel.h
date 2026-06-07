#pragma once
// Voice-editor model: the pure, platform-independent cursor + tokenization + edit logic
// extracted from EditorView (dictate.mm) so it can be unit-tested without AppKit
// (`make test`; gotcha #19). EditorView keeps the NSView rendering and the font-metric
// layout; it delegates word tokenization, cursor arithmetic, word replace/insert, and the
// per-line nearest-word search to the helpers here so there is ONE definition of each.
//
// Cursor model: `pos` addresses an alternating gap/word sequence — pos 0 = gap before
// word 0, pos 1 = word 0, pos 2 = gap after word 0, … For N words pos ∈ [0, 2N]; ODD = on
// a word, EVEN = in a gap (an insertion point).
#include <string>
#include <vector>
#include <cmath>
#include <cstddef>
#include "dictate_text.h"   // upper_cp_at / lower_cp_at — re-case a voice-corrected word to context

// ── cursor arithmetic (shared by EditorView + EditModel; single source of truth) ──
inline int  em_max_pos(int nwords) { return nwords * 2; }
inline bool em_on_word(int pos)    { return (pos % 2) == 1; }
inline int  em_word_index(int pos) { return (pos - 1) / 2; }   // valid when em_on_word(pos)
inline int  em_gap_index(int pos)  { return pos / 2; }         // valid when !em_on_word(pos)

// One ←/→ step (dir = -1 / +1), clamped to [0, maxPos]. Mirrors EditorView's keyDown:
// `if (_pos>0) _pos--` and `if (_pos<maxPos) _pos++`.
inline int em_clamp_step(int pos, int dir, int maxPos) {
    int p = pos + dir;
    if (p < 0) p = 0;
    if (p > maxPos) p = maxPos;
    return p;
}

// ── UTF-8 + punctuation helpers (the editor splits each punctuation mark into its own
//    token so the cursor can land on it and delete it; join re-glues with Russian spacing) ──

// Decode the UTF-8 sequence at s[i], advancing i past it; returns the codepoint. On a
// malformed lead/continuation byte it consumes ONE byte and returns it raw (never throws,
// never reads past end) — so a truncated multibyte tail can't loop or overrun.
inline unsigned em_utf8_next(const std::string &s, std::size_t &i) {
    unsigned char c = (unsigned char)s[i];
    if (c < 0x80) { i += 1; return c; }
    int n = (c >= 0xF0) ? 4 : (c >= 0xE0) ? 3 : (c >= 0xC0) ? 2 : 0;
    if (n == 0 || i + (std::size_t)n > s.size()) { i += 1; return c; }   // bad lead / truncated
    unsigned cp = (unsigned)(c & (0x7F >> n));
    for (int k = 1; k < n; k++) {
        unsigned char cc = (unsigned char)s[i + (std::size_t)k];
        if ((cc & 0xC0) != 0x80) { i += 1; return c; }                   // bad continuation
        cp = (cp << 6) | (unsigned)(cc & 0x3F);
    }
    i += (std::size_t)n; return cp;
}

// Codepoints that tokenize into their own token (a punctuation MARK). ASCII hyphen '-' and
// apostrophes are deliberately NOT here (they live inside words, e.g. «что-то»); the em/en
// dashes ARE, since Russian sets them off with spaces (a standalone, space-on-both-sides token).
inline bool em_is_punct_cp(unsigned cp) {
    switch (cp) {
        case '.': case ',': case '!': case '?': case ';': case ':':
        case '(': case ')': case '[': case ']': case '{': case '}': case '"':
        case 0x2026:  // … horizontal ellipsis
        case 0x2014:  // — em dash
        case 0x2013:  // – en dash
        case 0x00AB:  // « left guillemet
        case 0x00BB:  // » right guillemet
        case 0x201C:  // “ left double quote
        case 0x201D:  // ” right double quote
            return true;
        default: return false;
    }
}

// True iff the whole token is exactly one punctuation codepoint (status line: «на знаке»
// vs «на слове»). em_tokenize isolates each mark, so a punct token is one codepoint long.
inline bool em_is_punct_token(const std::string &t) {
    if (t.empty()) return false;
    std::size_t i = 0; unsigned cp = em_utf8_next(t, i);
    return i == t.size() && em_is_punct_cp(cp);
}

// A token plus its byte span [start, start+len) in the source string. Used to map
// whisper per-byte confidence onto words (src/dictate_conf.h) — a word's bytes are
// contiguous in `s`, so the span addresses exactly that word's characters.
struct EmSpan { std::string text; std::size_t start; std::size_t len; };

// Tokenizer with byte spans — split on ASCII whitespace AND isolate each punctuation mark
// (em_is_punct_cp) into its own token; drop empties. Non-punct multibyte UTF-8 (Cyrillic, …)
// and intra-word '-'/'’' pass through into the surrounding word intact. The single source of
// word boundaries: em_tokenize is a thin text-only wrapper over this.
inline std::vector<EmSpan> em_tokenize_spans(const std::string &s) {
    std::vector<EmSpan> out; std::string cur; std::size_t curStart = 0;
    auto flush = [&]{ if (!cur.empty()) { out.push_back({cur, curStart, cur.size()}); cur.clear(); } };
    std::size_t i = 0;
    while (i < s.size()) {
        std::size_t start = i;
        unsigned cp = em_utf8_next(s, i);
        if (cp==' '||cp=='\t'||cp=='\n'||cp=='\r'||cp=='\f'||cp=='\v') flush();
        else if (em_is_punct_cp(cp)) { flush(); out.push_back({s.substr(start, i - start), start, i - start}); }
        else { if (cur.empty()) curStart = start; cur.append(s, start, i - start); }
    }
    flush();
    return out;
}

// Token text only (drops the spans). Behaviour identical to the original em_tokenize.
inline std::vector<std::string> em_tokenize(const std::string &s) {
    std::vector<std::string> out;
    for (const EmSpan &sp : em_tokenize_spans(s)) out.push_back(sp.text);
    return out;
}

// ── punctuation-aware join (Russian spacing) ──
// No space BEFORE these (closing/trailing marks).
inline bool em_glue_left(const std::string &t) {
    return t=="." || t=="," || t=="!" || t=="?" || t==";" || t==":" ||
           t==")" || t=="]" || t=="}" ||
           t=="\xE2\x80\xA6" /*…*/ || t=="\xC2\xBB" /*»*/ || t=="\xE2\x80\x9D" /*”*/;
}
// No space AFTER these (opening marks).
inline bool em_glue_right(const std::string &t) {
    return t=="(" || t=="[" || t=="{" ||
           t=="\xC2\xAB" /*«*/ || t=="\xE2\x80\x9C" /*“*/;
}

// Join tokens with a single space at word↔token boundaries, except none before a glue-left
// mark or after a glue-right mark. The straight ASCII '"' is ambiguous, so it alternates:
// 1st/3rd/… occurrence opens (glues right), 2nd/4th/… closes (glues left). Dashes (—/–) are
// word-like → spaced both sides. Punctuation-free text → single space (matches the old
// componentsJoinedByString:@" ").
inline std::string em_join(const std::vector<std::string> &toks) {
    std::string out; int dq = 0; bool prevGlueR = false;
    for (std::size_t i = 0; i < toks.size(); i++) {
        const std::string &t = toks[i];
        bool isDQ = (t == "\"");
        bool openDQ = isDQ && (dq % 2 == 0);                  // even count so far → opener
        bool glueL = em_glue_left(t)  || (isDQ && !openDQ);   // closing " glues left
        bool glueR = em_glue_right(t) || (isDQ &&  openDQ);   // opening " glues right
        if (isDQ) dq++;
        if (i > 0 && !glueL && !prevGlueR) out += ' ';
        out += t;
        prevGlueR = glueR;
    }
    return out;
}

// Structural classification of the cursor, for the editor's status line. Mirrors
// EditorView::cursorDesc's branching (the Russian formatting stays in the view).
enum class CursorKind { empty, onWord, gapStart, gapEnd, gapBetween };
inline CursorKind em_cursor_kind(int nwords, int pos) {
    if (nwords == 0) return CursorKind::empty;
    if (em_on_word(pos)) return CursorKind::onWord;
    int g = em_gap_index(pos);
    if (g == 0)      return CursorKind::gapStart;
    if (g == nwords) return CursorKind::gapEnd;
    return CursorKind::gapBetween;
}

// A laid-out word cell for the per-line cursor search (↑/↓). EditorView builds these from
// its NSView layout (line index + the cell's mid-X); this stays font-metric-free.
struct EmCell { int line; double midX; int wordIndex; };

// Word on `targetLine` whose mid-X is nearest `anchorX`; -1 if the line has no word.
// Mirrors EditorView::lineMove's inner search (caret cells are not passed in).
inline int em_nearest_word_on_line(const std::vector<EmCell> &cells, int targetLine, double anchorX) {
    int best = -1; double bestD = 1e18;
    for (const auto &c : cells)
        if (c.line == targetLine) {
            double d = std::fabs(c.midX - anchorX);
            if (d < bestD) { bestD = d; best = c.wordIndex; }
        }
    return best;
}

// A freshly inserted / voice-corrected word is never flagged uncertain → full confidence.
inline constexpr float EM_CONF_SURE = 1.0f;

// ── mini-take cleanup (voice edit in the editor) ──────────────────────────────────────
// whisper transcribes a single dictated word as a standalone sentence — it Capitalizes it
// and appends a period («слово» → "Слово."). For a one-word voice correction that is wrong:
// the replacement must inherit the surrounding case and carry no spurious sentence dot. The
// helpers below clean a mini-take result before it is spliced in (applyMiniTake); they are
// pure + unit-tested (gotcha #19) and NOT applied to a normal take (normalize_text owns that).

// A token that is exactly one sentence-ending mark: . ! ? or … (U+2026).
inline bool em_is_sentence_punct(const std::string &t) {
    return t=="." || t=="!" || t=="?" || t=="\xE2\x80\xA6";
}

// First codepoint of `t` is a letter (ASCII or — crudely — any Cyrillic/multibyte lead).
inline bool em_first_is_letter(const std::string &t) {
    if (t.empty()) return false;
    unsigned char c0 = (unsigned char)t[0];
    return (c0>='A'&&c0<='Z') || (c0>='a'&&c0<='z') || c0>=0x80;
}
// First codepoint of `t` is an UPPERCASE letter (ASCII A–Z or Cyrillic А–Я incl. Ё).
inline bool em_first_is_upper(const std::string &t) {
    if (t.empty()) return false;
    unsigned char c0 = (unsigned char)t[0];
    if (c0>='A' && c0<='Z') return true;
    if (c0==0xD0 && t.size()>=2) {
        unsigned char c1 = (unsigned char)t[1];
        if (c1==0x81) return true;            // Ё
        if (c1>=0x90 && c1<=0xAF) return true; // А–Я
    }
    return false;
}
// Re-case the first letter of `t` to upper/lower in place (no-op on a non-letter lead).
inline void em_recase_first(std::string &t, bool upper) {
    if (t.empty()) return;
    if (upper) dictate_text_detail::upper_cp_at(t, 0);
    else       dictate_text_detail::lower_cp_at(t, 0);
}

// Lowercase a whole UTF-8 string (ASCII + Cyrillic) for case-insensitive phrase matching.
inline std::string em_to_lower(std::string s) {
    std::size_t i = 0;
    while (i < s.size()) { std::size_t st = i; em_utf8_next(s, i); dictate_text_detail::lower_cp_at(s, st); }
    return s;
}

// Map a whole spoken mini-take to a punctuation SYMBOL when the user dictated only a
// punctuation name (e.g. «знак вопроса» → "?", «точка» → "."). Returns "" when the phrase
// is not a known punctuation name, so the caller falls back to inserting it as words. The
// phrase is matched case-insensitively after dropping any punctuation whisper appended and
// collapsing whitespace — so "Знак вопроса." still maps. Lets the user insert marks the
// dictation otherwise can't produce on demand.
inline std::string em_spoken_punct(const std::string &raw) {
    std::string phrase;                                   // words only, single-spaced, lowercased
    for (const std::string &t : em_tokenize(raw)) {
        if (em_is_punct_token(t)) continue;
        if (!phrase.empty()) phrase += ' ';
        phrase += t;
    }
    phrase = em_to_lower(phrase);
    if (phrase.empty()) return "";
    struct Pair { const char *phrase; const char *sym; };
    static const Pair table[] = {
        {"точка с запятой", ";"},
        {"вопросительный знак", "?"}, {"знак вопроса", "?"},
        {"восклицательный знак", "!"}, {"знак восклицания", "!"},
        {"двоеточие", ":"},
        {"многоточие", "\xE2\x80\xA6"},                    // …
        {"длинное тире", "\xE2\x80\x94"}, {"тире", "\xE2\x80\x94"}, // —
        {"дефис", "-"},
        {"запятая", ","},
        {"точка", "."},
        {"открывающая скобка", "("}, {"открыть скобку", "("},
        {"закрывающая скобка", ")"}, {"закрыть скобку", ")"}, {"скобка", "("},
        {"открыть кавычки", "\xC2\xAB"}, {"открывающая кавычка", "\xC2\xAB"}, // «
        {"закрыть кавычки", "\xC2\xBB"}, {"закрывающая кавычка", "\xC2\xBB"}, // »
    };
    for (const Pair &p : table) if (phrase == p.phrase) return p.sym;
    return "";
}

// ── undo (voice editor) ───────────────────────────────────────────────────────────────
// A snapshot of the editor's mutable document — exactly the fields a CONTENT edit changes:
// the word list, the per-word confidence, and the cursor. Cursor moves (←/→ ↑/↓) are NOT
// edits and are never snapshotted, so undo reverts content changes (mini-take splices,
// deletes), not navigation. Pure + unit-tested (gotcha #19).
struct EditSnapshot {
    std::vector<std::string> words;
    std::vector<float>       conf;
    int                      pos = 0;
    // Document equality — drives "did this edit actually change anything?" (skip a no-op undo entry).
    // conf is compared too: re-dictating the SAME text over an uncertain word clears its amber
    // highlight (conf → EM_CONF_SURE) with words/pos unchanged — a real change that must be undoable.
    // Exact float compare is right here: conf is copied verbatim or set to exactly EM_CONF_SURE.
    bool operator==(const EditSnapshot &o) const { return pos == o.pos && words == o.words && conf == o.conf; }
    bool operator!=(const EditSnapshot &o) const { return !(*this == o); }
};

// ── the editor's word list + cursor as one value (used by EditorView via NSString↔std::string
//    bridging at the boundary, and tested directly here) ──
struct EditModel {
    std::vector<std::string> words;
    // Per-word confidence in [0,1], parallel to `words`. EMPTY when unknown (the text-only
    // path — fromText, the standalone editor). When non-empty it is kept aligned to `words`
    // through every edit below; inserted/corrected words get EM_CONF_SURE (never highlighted).
    std::vector<float> conf;
    int pos = 0;

    // Tokenize a transcript; cursor starts on the first word (pos 1), or 0 if empty.
    // Mirrors EditorView::initWithFrame:transcript:.
    static EditModel fromText(const std::string &t) {
        EditModel m; m.words = em_tokenize(t); m.pos = m.words.empty() ? 0 : 1; return m;
    }

    int  maxPos()    const { return em_max_pos((int)words.size()); }
    bool onWord()    const { return em_on_word(pos); }
    int  wordIndex() const { return em_word_index(pos); }
    int  gapIndex()  const { return em_gap_index(pos); }
    void stepLeft()  { pos = em_clamp_step(pos, -1, maxPos()); }
    void stepRight() { pos = em_clamp_step(pos, +1, maxPos()); }

    std::string joined() const { return em_join(words); }

    // Capture / restore the document for undo (src/dictate_editmodel.h, EditHistory below).
    EditSnapshot snapshot() const { return EditSnapshot{words, conf, pos}; }
    void restore(const EditSnapshot &s) { words = s.words; conf = s.conf; pos = s.pos; }

    // Splice already-tokenized words in at the cursor: replace the current word (on a word)
    // or insert at the current gap. Empty → no change. Cursor lands on the first new word.
    // Confidence stays aligned (new words → EM_CONF_SURE). Shared by applyResult/applyMiniTake.
    void applyTokens(const std::vector<std::string> &rw) {
        if (rw.empty()) return;
        if (onWord()) {
            int wi = wordIndex();
            words.erase(words.begin() + wi);
            words.insert(words.begin() + wi, rw.begin(), rw.end());
            if (!conf.empty()) { conf.erase(conf.begin() + wi);
                                 conf.insert(conf.begin() + wi, rw.size(), EM_CONF_SURE); }
            pos = 2 * wi + 1;
        } else {
            int gi = gapIndex();
            words.insert(words.begin() + gi, rw.begin(), rw.end());
            if (!conf.empty()) conf.insert(conf.begin() + gi, rw.size(), EM_CONF_SURE);
            pos = 2 * gi + 1;
        }
    }

    // Replace the current word / insert at the current gap with the tokenized result, verbatim
    // (no case/punct cleanup). Used by the text-only / stub path. Mirrors EditorView::applyResult:.
    void applyResult(const std::string &resultText) { applyTokens(em_tokenize(resultText)); }

    // Is the slot at word index `start` at a sentence start? True when nothing precedes it,
    // or the nearest preceding token (skipping closing quotes/brackets) is a sentence-ender.
    // Drives whether a voice-corrected word should be Capitalized or lowercased.
    bool atSentenceStart(int start) const {
        for (int j = start - 1; j >= 0; j--) {
            const std::string &t = words[j];
            if (em_is_sentence_punct(t)) return true;
            if (t=="\xC2\xBB" /*»*/ || t==")" || t=="]" || t=="\xE2\x80\x9D" /*”*/ || t=="\"") continue;
            return false;                       // a word (or non-closing punct) → mid-sentence
        }
        return true;                            // nothing before → sentence start
    }

    // Apply a VOICE mini-take (editor correction): the same splice as applyResult, but first
    //  (1) if the whole utterance names a punctuation mark → insert that symbol (em_spoken_punct);
    //  (2) else drop the spurious trailing sentence dot whisper appends to a dictated word, and
    //      re-case the first letter to the surrounding context (match the replaced word's case;
    //      at a gap, Capitalize only at a sentence start) — so a mid-sentence fix stays lowercase.
    void applyMiniTake(const std::string &raw) {
        std::string sym = em_spoken_punct(raw);
        if (!sym.empty()) { applyTokens({sym}); return; }
        std::vector<std::string> rw = em_tokenize(raw);
        if (rw.empty()) return;
        if (rw.size() > 1 && em_is_sentence_punct(rw.back())) rw.pop_back();   // strip whisper's auto dot
        if (em_first_is_letter(rw.front())) {
            int start = onWord() ? wordIndex() : gapIndex();
            bool upper = (onWord() && em_first_is_letter(words[wordIndex()]))
                       ? em_first_is_upper(words[wordIndex()])   // replace: inherit the old word's case
                       : atSentenceStart(start);                 // insert: capitalize only at a sentence start
            em_recase_first(rw.front(), upper);
        }
        applyTokens(rw);
    }

    // Erase token `idx` (caller guarantees 0 ≤ idx < size) and drop the cursor into the gap
    // it left behind. Shared by deleteToken/deleteForward. No clamp needed: idx < new size
    // ⇒ 2*idx ≤ 2*(new size) = maxPos(), so pos stays in range by construction.
    void eraseAt(int idx) {
        words.erase(words.begin() + idx);
        if (!conf.empty()) conf.erase(conf.begin() + idx);
        pos = words.empty() ? 0 : 2 * idx;
    }

    // Delete the current word (on a word) or the token before the cursor (in a gap —
    // backspace). No-op in the leading gap (nothing to the left). Cursor lands in the gap
    // the token left behind. Mirrors keyCode 51 (Delete/Backspace).
    void deleteToken() {
        if (words.empty()) { pos = 0; return; }
        if (onWord()) { eraseAt(wordIndex()); return; }
        int gi = gapIndex(); if (gi == 0) return;   // leading gap → nothing to backspace
        eraseAt(gi - 1);
    }

    // Forward-delete: remove the current word (on a word) or the next token (in a gap).
    // No-op in the trailing gap. Cursor stays in the gap so repeated presses chew forward.
    // Mirrors keyCode 117 (fn+Delete / forward delete).
    void deleteForward() {
        if (words.empty()) { pos = 0; return; }
        if (onWord()) { eraseAt(wordIndex()); return; }
        int gi = gapIndex(); if (gi >= (int)words.size()) return;  // trailing gap → nothing ahead
        eraseAt(gi);
    }
};

// Bounded undo/redo history for the editor. `recordEdit(before)` is called by the view on a real
// content edit: it pushes the PRE-edit snapshot for undo and invalidates the redo stack (a fresh
// edit forks history). undo()/redo() swap the current document against the top of one stack and
// park it on the other, so the pair round-trips losslessly. Both stacks are capacity-bounded
// (oldest dropped) so a long session can't grow without bound. Pure + unit-tested (gotcha #19);
// EditorView (dictate.mm) owns one and bridges NSArray↔snapshot.
struct EditHistory {
    std::vector<EditSnapshot> undoStack;
    std::vector<EditSnapshot> redoStack;
    std::size_t cap = 200;                                  // per stack; an editor take is short-lived

    static void boundedPush(std::vector<EditSnapshot> &v, const EditSnapshot &s, std::size_t cap) {
        v.push_back(s);
        if (v.size() > cap) v.erase(v.begin());             // drop the oldest beyond the cap
    }
    // A real content edit happened: record the pre-edit state for undo, and drop any redo future.
    void recordEdit(const EditSnapshot &before) { boundedPush(undoStack, before, cap); redoStack.clear(); }

    bool canUndo() const { return !undoStack.empty(); }
    bool canRedo() const { return !redoStack.empty(); }

    // Undo: return the previous state in `out`, parking `current` on the redo stack. Returns false
    // (out untouched) when there is nothing to undo. `current` and `out` must NOT alias.
    bool undo(const EditSnapshot &current, EditSnapshot &out) {
        if (undoStack.empty()) return false;
        out = undoStack.back(); undoStack.pop_back();
        boundedPush(redoStack, current, cap);
        return true;
    }
    // Redo: the inverse — return the next state in `out`, parking `current` back on the undo stack.
    bool redo(const EditSnapshot &current, EditSnapshot &out) {
        if (redoStack.empty()) return false;
        out = redoStack.back(); redoStack.pop_back();
        boundedPush(undoStack, current, cap);
        return true;
    }
    void clear() { undoStack.clear(); redoStack.clear(); }
};
