#pragma once

#include <algorithm>
#include <exception>
#include <stdexcept>
#include <string_view>

namespace transcriber {

// Core ML is the accepted fast default; CPU remains available for comparison
// and as a fallback when accelerated inference fails.
inline bool diarization_use_coreml(const char* requested) {
    const std::string_view provider = requested ? requested : "auto";
    if (provider == "coreml" || provider == "auto") return true;
    if (provider == "cpu") return false;
    throw std::invalid_argument("TRANSCRIBER_DIARIZATION_PROVIDER must be auto, coreml or cpu");
}

// ONNX CPU inference scales well up to the eight performance cores measured on
// the development Mac. Keep unknown hardware conservative and avoid E-core pools.
inline int diarization_cpu_threads(int performance_cores) {
    return performance_cores > 0 ? std::min(performance_cores, 8) : 2;
}

// run(true) uses acceleration; run(false) uses CPU. Each attempt owns and
// destroys its inference contexts before this function starts another attempt.
template <class Run, class OnFallback>
auto with_diarization_fallback(bool accelerated, Run&& run, OnFallback&& notice)
    -> decltype(run(false)) {
    if (accelerated) {
        try { return run(true); }
        catch (const std::exception& error) { notice(error.what()); }
    }
    return run(false);
}

}  // namespace transcriber
