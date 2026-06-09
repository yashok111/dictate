#include "doctest.h"
#include "dictate_capture.h"

TEST_CASE("capture stop finalizes only after an audio callback delivered samples") {
    CHECK(capture_stop_action(false, 0) == CaptureStopAction::reportNoAudio);
    CHECK(capture_stop_action(false, 1600) == CaptureStopAction::reportNoAudio);
    CHECK(capture_stop_action(true, 0) == CaptureStopAction::reportNoAudio);
    CHECK(capture_stop_action(true, 1600) == CaptureStopAction::transcribe);
}

TEST_CASE("capture banner includes the current input source") {
    CHECK(capture_banner_text("🎙  ЗАПИСЬ — говори", "MacBook Pro Microphone",
                              "⌘⇧D — стоп · Esc — отмена")
          == "🎙  ЗАПИСЬ — говори\nВход: MacBook Pro Microphone\n⌘⇧D — стоп · Esc — отмена");
    CHECK(capture_banner_text("⏳  Запуск микрофона…", "", "")
          == "⏳  Запуск микрофона…\nВход: не выбран");
}
