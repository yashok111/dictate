#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <utility>
#include <vector>

namespace transcriber {

// Silero GGML v6.2.0 at 16 kHz produces one probability per 512 samples.
// A missing or malformed map must never remove recognized speech.
class ConservativeVad {
public:
    ConservativeVad() = default;
    ConservativeVad(std::vector<float> probabilities, int64_t samples)
        : probabilities_(std::move(probabilities)), samples_(samples) {
        valid_ = samples > 0 && uint64_t((samples - 1) / 512 + 1) == probabilities_.size() &&
            std::all_of(probabilities_.begin(), probabilities_.end(), [](float value) {
                return std::isfinite(value) && value >= 0 && value <= 1;
            });
    }
    bool valid() const { return valid_; }
    bool skip_window(int64_t begin, int64_t end) const {
        if (!valid_ || begin < 0 || end <= begin || end > samples_ || end - begin < 5 * 16000) return false;
        constexpr int64_t margin = 16000;
        const int64_t padded_begin = std::max<int64_t>(0, begin - margin);
        const int64_t padded_end = end > samples_ - margin ? samples_ : end + margin;
        const auto first = static_cast<size_t>(padded_begin / 512);
        const auto last = static_cast<size_t>((padded_end - 1) / 512 + 1);
        return std::all_of(probabilities_.begin() + first, probabilities_.begin() + last,
                           [](float value) { return value < 0.10f; });
    }
private:
    std::vector<float> probabilities_;
    int64_t samples_{0};
    bool valid_{false};
};
}  // namespace transcriber
