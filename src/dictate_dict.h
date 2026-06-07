#pragma once
// User dictionary → whisper `initial_prompt` (lexical bias), the pure / platform-independent
// logic extracted so it is unit-testable without whisper/AppKit (gotcha #19). dictate.mm
// reads the env + file, calls build_initial_prompt() once at startup, and stores the result
// in a process-lifetime global whose c_str() make_params points whisper_full_params.initial_prompt
// at. This header owns ONLY: parsing the dictionary text, prioritizing entries, and assembling
// a token-budgeted prompt string. No I/O, no platform deps — just std::string.
//
// Why a prompt at all: whisper.cpp biases the decoder toward words seen in initial_prompt (it
// is fed as prior-context tokens). Seeding the user's names / tech terms / English-in-Russian
// words raises their recognition WITHOUT changing the model — the main accuracy lever here.
//
// Token budget (gotcha #11): whisper's prompt is capped at n_text_ctx/2 = 224 tokens, and the
// turbo model is prompt-sensitive — a long or sentence-like prompt makes it loop/hallucinate.
// We can't run whisper's BPE tokenizer here (no whisper/ctx — gotcha #19), so we budget by a
// conservative token ESTIMATE and assemble the kept entries as a short comma-separated vocab
// list (NOT prose), staying well under the cap. Order in the file is the priority: the
// earliest entries are the most important and are kept first when the budget is tight.
#include <string>
#include <vector>
#include <unordered_set>
#include <cstddef>

namespace dict {

// Default whisper prompt-token cap (n_text_ctx/2 for large-v3). The assembled prompt is held
// at or under this many ESTIMATED tokens; dictate.mm lets WHISPER_PROMPT_MAXTOK tune it down
// if the turbo model is seen to loop (gotcha #11).
constexpr std::size_t DEFAULT_MAX_TOKENS = 224;

// Conservative upper-leaning estimate of how many whisper BPE tokens [s] costs. We can't call
// the real tokenizer here (gotcha #19), so we approximate: whisper's multilingual BPE averages
// ~2-3 chars/token, but rare names/terms — exactly this dictionary's content — fragment denser,
// and each whitespace-separated word adds a leading-space token. ceil(codepoints/2) + words
// leans high on purpose: we would rather under-fill the budget than overflow the 224-cap and
// risk turbo looping. Counts UTF-8 code points (a 2-byte Cyrillic char is one), not bytes.
inline std::size_t estimate_tokens(const std::string &s) {
    std::size_t chars = 0, words = 0;
    bool in_word = false;
    for (unsigned char c : s) {
        if ((c & 0xC0) == 0x80) continue;            // UTF-8 continuation byte → same code point
        if (c == ' ' || c == '\t') { in_word = false; continue; }
        ++chars;                                     // non-space code point
        if (!in_word) { ++words; in_word = true; }
    }
    return (chars + 1) / 2 + words;                  // ~2 chars/token, +1 leading-space token/word
}

// Parse dictionary file text into prioritized entries. ONE entry per line; the order in the
// file IS the priority (earliest = most important, kept first under the budget). Rules:
//   • '#' starts a comment to end of line, but ONLY at line start or after whitespace — so a
//     tech term like "C#" or "F#" survives, while "термин  # note" drops the note.
//   • leading/trailing ASCII whitespace (space/tab/CR/LF) is trimmed.
//   • blank lines (after comment-strip + trim) are skipped.
//   • exact duplicates (after trim) are dropped, keeping the FIRST (highest-priority) one.
inline std::vector<std::string> parse_dictionary(const std::string &content) {
    std::vector<std::string> out;
    std::unordered_set<std::string> seen;            // O(1) dedup membership; `out` keeps order
    auto add_line = [&](std::string ln) {
        // strip trailing comment: '#' at line start or following whitespace (keeps "C#"/"F#")
        for (std::size_t i = 0; i < ln.size(); ++i) {
            if (ln[i] == '#' && (i == 0 || ln[i - 1] == ' ' || ln[i - 1] == '\t')) {
                ln.erase(i);
                break;
            }
        }
        // trim ASCII whitespace
        std::size_t a = ln.find_first_not_of(" \t\r\n");
        if (a == std::string::npos) return;          // blank / comment-only line
        std::size_t b = ln.find_last_not_of(" \t\r\n");
        ln = ln.substr(a, b - a + 1);
        if (!seen.insert(ln).second) return;         // dedup, keep first occurrence
        out.push_back(std::move(ln));
    };
    // Split on '\n', '\r', or "\r\n": find_first_of treats a lone CR (classic-Mac files) as a
    // separator too, and the empty piece a "\r\n" pair leaves behind is dropped as a blank line.
    std::size_t start = 0;
    while (true) {
        std::size_t nl = content.find_first_of("\r\n", start);
        if (nl == std::string::npos) { add_line(content.substr(start)); break; }
        add_line(content.substr(start, nl - start));
        start = nl + 1;
    }
    return out;
}

// Assemble the initial_prompt from prioritized entries: greedily add whole entries (highest
// priority first) while the running token estimate stays within [max_tokens]. An entry that
// would overflow is SKIPPED and the next (possibly smaller) one is tried — this fills the
// budget without ever exceeding it. Kept entries are joined ", " into a short vocab list (NOT
// prose) so the decoder is biased without a runaway sentence (gotcha #11). Returns "" if no
// entry fits or there are none.
inline std::string build_prompt(const std::vector<std::string> &entries,
                                std::size_t max_tokens = DEFAULT_MAX_TOKENS) {
    std::string prompt;
    std::size_t used = 0;
    for (const auto &e : entries) {
        std::size_t cost = estimate_tokens(e) + (prompt.empty() ? 0 : 1);  // +1 ≈ the ", " separator
        if (used + cost > max_tokens) continue;       // too big — skip, keep trying smaller ones
        if (!prompt.empty()) prompt += ", ";
        prompt += e;
        used += cost;
    }
    return prompt;
}

// Convenience: parse raw dictionary text and assemble the budgeted prompt in one call.
inline std::string build_initial_prompt(const std::string &content,
                                        std::size_t max_tokens = DEFAULT_MAX_TOKENS) {
    return build_prompt(parse_dictionary(content), max_tokens);
}

}  // namespace dict
