#pragma once
#include <cctype>
#include <string>
#include <vector>
#include "policy.h"

namespace transcriber {
struct AsrWord {
    int64_t start_ms;
    int64_t end_ms;
    std::string text;
    bool timing_uncertain{false};
};

// Whisper's experimental word timestamps sometimes give real words zero width.
// Retain them with the next timed word, preserving recognition order. A trailing
// untimed run has only a bounded time range and must not acquire a speaker.
class AsrWordCollector {
public:
    AsrWordCollector(int64_t core_start, int64_t core_end)
        : core_start_(core_start), core_end_(core_end) {}
    void add(int64_t start, int64_t end, std::string text) {
        if (text.empty() || start < 0 || end < start) return;
        if (start == end) {
            if (start < core_start_ || start >= core_end_) return;
            if (pending_.empty()) pending_start_ = start;
            else pending_ += " ";
            pending_ += text;
            // A zero-width word has no timing of its own: whatever it is merged into is not
            // reliably timed either (its start is stretched back over this token) (F138).
            pending_uncertain_ = true;
            return;
        }
        auto interval = owned_word_interval(start, end, core_start_, core_end_);
        if (interval.second <= interval.first) return;
        // Do not stretch a reliably timed word backwards over a long silent
        // gap merely to retain an earlier zero-duration token.
        if (!pending_.empty() && interval.first - pending_start_ > 500 &&
            (words_.empty() || words_.back().start_ms < interval.first)) {
            const auto beginning = words_.empty() ? pending_start_ : std::max(pending_start_, words_.back().start_ms);
            words_.push_back({beginning, interval.first, std::move(pending_), true});
            pending_.clear();
            pending_uncertain_ = false;
        }
        if (!pending_.empty()) {
            interval.first = std::min(interval.first, pending_start_);
            interval.second = std::max(interval.second, pending_start_);
            text = pending_ + " " + text;
            pending_.clear();
        }
        if (!words_.empty()) interval.first = std::max(interval.first, words_.back().start_ms);
        if (interval.second <= interval.first) {
            pending_ = std::move(text);
            pending_start_ = interval.first;
            pending_uncertain_ = true;
            return;
        }
        words_.push_back({interval.first, interval.second, std::move(text), pending_uncertain_});
        pending_uncertain_ = false;
    }
    std::vector<AsrWord> finish() {
        if (!pending_.empty()) {
            const auto start = words_.empty() ? pending_start_ : std::max(pending_start_, words_.back().start_ms);
            words_.push_back({start, core_end_, std::move(pending_), true});
            pending_.clear();
        }
        return std::move(words_);
    }
private:
    int64_t core_start_, core_end_, pending_start_{0};
    std::string pending_;
    bool pending_uncertain_{false};
    std::vector<AsrWord> words_;
};

// Window seams (F166). Each 25 s window times the words near its core boundary with its own
// audio context, so deciding ownership by each window's own midpoint could keep a straddling
// word in both windows or in neither. Windows therefore collect words whose midpoint lies within
// SEAM_SLACK_MS of their core (a small overlap, never a gap), and the join drops the second copy
// of a word both windows kept.
inline constexpr int64_t SEAM_SLACK_MS = 150;

// The word's text without surrounding spaces and ASCII punctuation — "привет," and "привет"
// are one word for the seam check.
inline std::string seam_key(const std::string& t) {
    auto skip = [](unsigned char c) { return c == ' ' || (c < 0x80 && std::ispunct(c)); };
    size_t a = 0, b = t.size();
    while (a < b && skip(static_cast<unsigned char>(t[a]))) ++a;
    while (b > a && skip(static_cast<unsigned char>(t[b - 1]))) --b;
    return t.substr(a, b - a);
}

// `next` (from the later window) repeats `prev` (the last word kept from the earlier window):
// same word, and it starts before `prev` ended plus the slack.
inline bool duplicate_at_seam(const AsrWord& prev, const AsrWord& next) {
    const std::string key = seam_key(next.text);
    return !key.empty() && key == seam_key(prev.text) && next.start_ms < prev.end_ms + SEAM_SLACK_MS;
}
}  // namespace transcriber
