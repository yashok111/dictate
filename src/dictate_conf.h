#pragma once
// Per-word confidence for the editor's uncertain-word highlighting (whisper logprob).
// whisper.cpp yields a probability per BPE subword token (whisper_full_get_token_p); this
// maps those onto the editor's WORD tokenization (em_tokenize) so EditorView can dim/colour
// low-confidence words, leading the eye straight to likely transcription errors.
//
// PURE + unit-tested (gotcha #19): no AppKit / no whisper here. dictate.mm pulls the
// (text, prob) token list out of whisper and feeds it in; the daemon serializes the result
// across the process boundary to the editor (argv `--conf`), which parses it back.
#include <string>
#include <vector>
#include <cmath>
#include <cstddef>
#include "dictate_editmodel.h"   // em_tokenize_spans — single source of word boundaries

namespace conf {

// One whisper subword token: its detokenized text and decode probability in [0,1].
struct Token { std::string text; float p; };

// Per-word confidence over em_tokenize of the concatenated token texts. A word's score is
// the MINIMUM probability among the whisper tokens whose bytes fall inside it — a word is
// only as trustworthy as its least-certain subword piece. The words come from
// em_tokenize_spans on the SAME concatenation, so the result aligns 1:1 with the editor's
// tokenization of the identical transcript text (the editor re-tokenizes the joined parts;
// see the daemon's per-segment assembly). A word with no covering byte → 1.0 (confident).
inline std::vector<float> words_confidence(const std::vector<Token> &toks) {
    std::string s; std::vector<float> pb;            // pb[i] = prob of the token owning byte i
    for (const Token &t : toks)
        for (char c : t.text) { s.push_back(c); pb.push_back(t.p); }
    std::vector<float> out;
    for (const EmSpan &sp : em_tokenize_spans(s)) {
        float m = 2.0f;                              // sentinel above any real prob
        for (std::size_t i = sp.start; i < sp.start + sp.len && i < pb.size(); i++)
            if (pb[i] < m) m = pb[i];
        out.push_back(m > 1.5f ? 1.0f : m);          // no covering byte → confident
    }
    return out;
}

// Serialize per-word confidence for the editor argv (`--conf`): comma-separated integers,
// each = prob*1000 rounded, clamped to [0,1000]. Empty in → empty string (→ no highlights).
inline std::string serialize(const std::vector<float> &c) {
    std::string out;
    for (std::size_t i = 0; i < c.size(); i++) {
        if (i) out += ',';
        long v = std::lround((double)c[i] * 1000.0);
        if (v < 0) v = 0;
        if (v > 1000) v = 1000;
        out += std::to_string(v);
    }
    return out;
}

// Parse the argv conf string back to per-word prob in [0,1]. Returns EMPTY (→ feature
// disabled, no highlighting) unless the parsed count == expectN: the editor's own word count
// must match exactly, so any drift disables colouring instead of mis-painting words. Tolerant
// of stray non-digit bytes (ignored); each field clamps to [0,1].
inline std::vector<float> parse(const std::string &s, std::size_t expectN) {
    std::vector<float> out;
    if (!s.empty()) {
        long v = 0;
        auto push = [&]{ if (v > 1000) v = 1000; out.push_back((float)v / 1000.0f); v = 0; };
        for (char ch : s) {
            if (ch == ',') push();
            else if (ch >= '0' && ch <= '9') { v = v * 10 + (ch - '0'); if (v > 1000000) v = 1000000; }
            // any other byte: ignored (defensive)
        }
        push();   // final field after the last comma
    }
    if (out.size() != expectN) return {};
    return out;
}

// Re-align per-word confidence from the RAW transcript onto the FINALIZED transcript's
// tokenization. finalize_transcript (capitalization / punctuation / typography) preserves the
// SEQUENCE of non-punctuation WORDS — it only re-cases them and rewrites punctuation tokens
// (e.g. "..."→"…", a spaced "-"→"—") — so confidence maps positionally over the non-punct
// subsequence; punctuation tokens (which the editor never highlights) get EM_CONF_SURE. The
// result has length em_tokenize(finalText).size() so the editor's per-word count check matches.
// Returns EMPTY (→ highlighting disabled, never mis-painted) if the non-punct word counts differ
// (a rare transform that adds/removes a real word) or rawConf isn't aligned to rawText.
inline std::vector<float> realign(const std::string &rawText, const std::vector<float> &rawConf,
                                  const std::string &finalText) {
    std::vector<std::string> R = em_tokenize(rawText);
    if (R.size() != rawConf.size()) return {};
    std::vector<float> rawNon;                          // confidence of raw NON-punct words, in order
    for (std::size_t i = 0; i < R.size(); i++)
        if (!em_is_punct_token(R[i])) rawNon.push_back(rawConf[i]);
    std::vector<std::string> G = em_tokenize(finalText);
    std::size_t nonG = 0;
    for (const std::string &g : G) if (!em_is_punct_token(g)) nonG++;
    if (nonG != rawNon.size()) return {};               // a real word was added/removed → disable cleanly
    std::vector<float> out; out.reserve(G.size());
    std::size_t k = 0;
    for (const std::string &g : G)
        out.push_back(em_is_punct_token(g) ? EM_CONF_SURE : rawNon[k++]);
    return out;
}

} // namespace conf
