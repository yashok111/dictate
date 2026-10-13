#pragma once

#include <algorithm>
#include <cstdint>
#include <map>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace transcriber {
struct Profile {
    std::string id;
    uint64_t peak_bytes;
    int quality_rank;
    bool installed;
};
struct Turn { int64_t start_ms; int64_t end_ms; int32_t speaker; };
struct Attribution { int32_t speaker{-1}; bool overlap{false}; };
struct AudioPlacement { uint64_t gap; uint64_t skip; uint64_t take; };
// Midpoint ownership avoids duplicate context words. Clip the retained interval
// to its owning core so timestamps cannot go backwards at a window boundary.
// Keep recognition order: sorting words by noisy context timestamps changes text.
inline std::pair<int64_t, int64_t> owned_word_interval(int64_t start, int64_t end,
                                                      int64_t core_start, int64_t core_end) {
    if (start < 0 || end <= start || core_start < 0 || core_end <= core_start) return {0, 0};
    const auto middle = start + (end - start) / 2;
    if (middle < core_start || middle >= core_end) return {0, 0};
    return {std::max(start, core_start), std::min(end, core_end)};
}
inline AudioPlacement place_audio(uint64_t written, int64_t timestamp, uint64_t samples) {
    if (timestamp >= 0 && static_cast<uint64_t>(timestamp) > written)
        return {static_cast<uint64_t>(timestamp) - written, 0, samples};
    uint64_t skip;
    if (timestamp >= 0) {
        skip = std::min(samples, written - static_cast<uint64_t>(timestamp));
    } else {
        // Clamp each part before adding: even INT64_MIN and UINT64_MAX are safe.
        const auto priming = static_cast<uint64_t>(-(timestamp + 1)) + 1;
        const auto already_written = std::min(samples, written);
        skip = already_written + std::min(samples - already_written, priming);
    }
    return {0, skip, samples - skip};
}

inline std::string select_profile(const std::vector<Profile>& profiles,
                                  uint64_t headroom, uint64_t reserve, bool pressure) {
    if (pressure || reserve > headroom) return {};
    const Profile* best = nullptr;
    for (const auto& profile : profiles) {
        if (!profile.installed || profile.peak_bytes == 0 || profile.id.empty()) continue;
        if (profile.peak_bytes > headroom - reserve) continue;
        if (!best || profile.quality_rank > best->quality_rank) best = &profile;
    }
    return best ? best->id : std::string{};
}
// Conservative paragraph-level attribution. A mixed paragraph remains unknown
// unless one speaker covers >60% of it and no simultaneous voices occur.
inline Attribution attribute(int64_t start, int64_t end, const std::vector<Turn>& turns) {
    if (start < 0 || end <= start) throw std::invalid_argument("invalid interval");
    using Interval = std::pair<int64_t, int64_t>;
    std::map<int32_t, std::vector<Interval>> by_speaker;
    for (const auto& turn : turns) {
        if (turn.start_ms < 0 || turn.end_ms <= turn.start_ms || turn.speaker < 0)
            throw std::invalid_argument("invalid speaker turn");
        const auto a = std::max(start, turn.start_ms), b = std::min(end, turn.end_ms);
        if (a < b) by_speaker[turn.speaker].push_back({a, b});
    }
    std::vector<Turn> merged;
    int32_t best = -1;
    int64_t best_coverage = 0;
    for (auto& entry : by_speaker) {
        auto& intervals = entry.second;
        std::sort(intervals.begin(), intervals.end());
        auto current = intervals.front();
        int64_t coverage = 0;
        auto emit = [&] {
            coverage += current.second - current.first;
            merged.push_back({current.first, current.second, entry.first});
        };
        for (size_t i = 1; i < intervals.size(); ++i) {
            if (intervals[i].first <= current.second)
                current.second = std::max(current.second, intervals[i].second);
            else { emit(); current = intervals[i]; }
        }
        emit();
        if (coverage > best_coverage) { best_coverage = coverage; best = entry.first; }
    }
    for (size_t i = 0; i < merged.size(); ++i)
        for (size_t j = i + 1; j < merged.size(); ++j)
            if (merged[i].speaker != merged[j].speaker &&
                std::max(merged[i].start_ms, merged[j].start_ms) <
                std::min(merged[i].end_ms, merged[j].end_ms)) return {-1, true};
    return {static_cast<long double>(best_coverage) / (end - start) > 0.6L ? best : -1, false};
}

// Word timestamps and speech boundaries come from independent models. Bridge
// only a short gap or partial coverage to one unambiguous voice; never resolve mixed evidence
// by proximity. Paragraph attribution above deliberately remains strict.
inline Attribution attribute_word(int64_t start, int64_t end, const std::vector<Turn>& turns) {
    const auto direct = attribute(start, end, turns);
    if (direct.speaker >= 0 || direct.overlap || end - start > 1000) return direct;
    int32_t nearby = -1;
    for (const auto& turn : turns) {
        const auto gap = turn.end_ms <= start ? start - turn.end_ms :
                         turn.start_ms >= end ? turn.start_ms - end : int64_t{0};
        if (gap > 500) continue;
        if (nearby >= 0 && nearby != turn.speaker) return direct;
        nearby = turn.speaker;
    }
    return {nearby, false};
}
}  // namespace transcriber
