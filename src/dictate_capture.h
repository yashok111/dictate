#pragma once
#include <cstddef>
#include <string>

enum class CaptureStopAction {
    transcribe,
    reportNoAudio,
};

inline CaptureStopAction capture_stop_action(bool live, std::size_t samples) {
    return live && samples > 0 ? CaptureStopAction::transcribe
                               : CaptureStopAction::reportNoAudio;
}

inline std::string capture_banner_text(const std::string &status,
                                       const std::string &input_source,
                                       const std::string &controls) {
    std::string out = status + "\nВход: " + (input_source.empty() ? "не выбран" : input_source);
    if (!controls.empty()) out += "\n" + controls;
    return out;
}
