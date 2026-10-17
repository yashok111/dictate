WHISPER := $(shell brew --prefix whisper-cpp)
GGML := $(shell brew --prefix ggml)
ORT := $(CURDIR)/.deps/onnxruntime
CXXFLAGS := -std=c++17 -fobjc-arc -O2 -Wall -Wextra -Wno-deprecated-declarations \
 -I$(WHISPER)/include -I$(GGML)/include -I.deps/onnxruntime \
 -DGGML_LIBEXEC='"$(GGML)/libexec"'
LDFLAGS := -L$(WHISPER)/lib -L$(GGML)/lib \
 -lwhisper -lggml -lggml-base -L$(ORT) -lonnxruntime -Wl,-rpath,$(ORT) \
 -Wl,-rpath,$(WHISPER)/lib -Wl,-rpath,$(GGML)/lib \
 -framework Foundation -framework AVFoundation -framework CoreMedia -framework AudioToolbox

# onnxruntime (headers + dylib) is not in the tree: scripts/setup-alignment.py fetches it into
# .deps/. Order-only prerequisites, so a missing download fails with the fix, not a fatal #include.
ORT_HDR := .deps/onnxruntime/onnxruntime_cxx_api.h
ORT_LIB := .deps/onnxruntime/libonnxruntime.dylib
$(ORT_HDR) $(ORT_LIB):
	@echo "✖ $@ is missing — run from the repo root: python3 transcriber/scripts/setup-alignment.py" >&2; exit 1

.PHONY: worker release-worker test test-pipeline analyze
worker: build/transcriber-worker
release-worker: build/release/transcriber-worker
build/release/transcriber-worker: native/worker.mm native/forced_alignment.h core/ctc_alignment.h native/speaker_cache.h native/prepared_audio.h native/transcript_rows.h native/vad_filter.h core/policy.h core/asr_words.h core/diarization.h core/vad.h ../src/dictate_dict.h ../src/dictate_text.h Makefile | $(ORT_HDR) $(ORT_LIB)
	mkdir -p build/release
	clang++ $(CXXFLAGS) -mmacosx-version-min=26.0 -DTRANSCRIBER_BUNDLED $< -o $@ $(LDFLAGS)
build/transcriber-worker: native/worker.mm native/forced_alignment.h core/ctc_alignment.h native/speaker_cache.h native/prepared_audio.h native/transcript_rows.h native/vad_filter.h core/policy.h core/asr_words.h core/diarization.h core/vad.h ../src/dictate_dict.h ../src/dictate_text.h Makefile | $(ORT_HDR) $(ORT_LIB)
	mkdir -p build
	clang++ $(CXXFLAGS) $< -o $@ $(LDFLAGS)
build/test-pipeline: tests/test_pipeline.mm native/speaker_cache.h native/prepared_audio.h native/transcript_rows.h core/policy.h
	mkdir -p build
	clang++ -std=c++17 -fobjc-arc -O2 -Wall -Wextra -Wno-deprecated-declarations $< -framework Foundation -o $@
test-pipeline: build/test-pipeline
	./build/test-pipeline
test: worker test-pipeline
	python3 tests/test_worker.py
	python3 tests/test_prepared_pipeline.py

# Clang Static Analyzer over worker.mm (same flags as the top-level `make analyze`). Needs only
# the onnxruntime headers, not the dylib.
analyze: native/worker.mm | $(ORT_HDR)
	clang++ $(CXXFLAGS) --analyze -Xclang -analyzer-output=text -Xclang -analyzer-werror $< -o /dev/null
