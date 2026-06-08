# dictate — native macOS dictation (AVFoundation capture + whisper.cpp)
# Links against Homebrew's libwhisper/libggml; needs Xcode CLT for the frameworks.

# Resolve Homebrew prefixes only when a goal actually needs them — `make clean` / `make test`
# don't (the unit tests link no whisper/ggml) — and fail early with an actionable message if a
# dependency is missing. Resolve unless EVERY goal is brew-free; the default no-goal build and
# any mac-only goal mixed in (e.g. `make test tsan`) still resolve. `$(or …,build)` makes the
# no-goal case look like a real build target.
ifneq ($(filter-out clean test,$(or $(MAKECMDGOALS),build)),)
WHISPER := $(shell brew --prefix whisper-cpp 2>/dev/null)
GGML    := $(shell brew --prefix ggml 2>/dev/null)
ifeq ($(WHISPER),)
$(error whisper-cpp not found — run: brew install whisper-cpp)
endif
ifeq ($(GGML),)
$(error ggml not found — run: brew install ggml)
endif
endif

CXX      := clang++
CXXFLAGS := -std=c++17 -fobjc-arc -O2 -Wall -Wextra \
            -I$(WHISPER)/include -I$(GGML)/include \
            -DGGML_LIBEXEC='"$(GGML)/libexec"'
LDFLAGS  := -L$(WHISPER)/lib -L$(GGML)/lib -lwhisper -lggml -lggml-base \
            -framework Foundation -framework AVFoundation -framework AppKit \
            -framework Accelerate -framework Carbon -framework ApplicationServices \
            -framework CoreAudio
# Bake the dylib dirs into the binary so it runs without DYLD_LIBRARY_PATH.
LDFLAGS  += -Wl,-rpath,$(WHISPER)/lib -Wl,-rpath,$(GGML)/lib

BIN   := dictate
SRC   := src/dictate.mm
# Embedded via -sectcreate so TCC has NSMicrophoneUsageDescription (gotcha #2). Kept in src/
# (NOT next to the built binary): a loose Info.plist beside ./dictate makes codesign treat it
# as a bundle (Format=bundle + _CodeSignature/), which breaks on `cp dictate ~/.local/bin/`.
PLIST := src/Info.plist

# Stable code-signing identity → TCC grants (Mic/Accessibility) survive rebuilds.
# A plain ad-hoc binary is keyed by cdhash, which changes every build, so grants
# break each time. Create the identity once: `scripts/make-codesign-cert.sh`.
# Absent → the binary is left ad-hoc (works, but grants won't persist). See gotcha #14.
SIGN_ID    ?= dictate-codesign
SIGN_IDENT ?= com.user.dictate

$(BIN): $(SRC) Makefile $(PLIST)
	$(CXX) $(CXXFLAGS) $(SRC) -o $(BIN) $(LDFLAGS) -sectcreate __TEXT __info_plist $(PLIST)
	@if security find-identity -p codesigning 2>/dev/null | grep -q "\"$(SIGN_ID)\""; then \
	    codesign --force --identifier "$(SIGN_IDENT)" --sign "$(SIGN_ID)" $(BIN) \
	      && echo "✓ signed $(BIN): $(SIGN_IDENT) / $(SIGN_ID) (TCC-stable)"; \
	  else \
	    echo "⚠ codesigning identity '$(SIGN_ID)' not found — $(BIN) left ad-hoc"; \
	    echo "  (TCC grants break on each rebuild; run scripts/make-codesign-cert.sh once)"; \
	  fi

run: $(BIN)
	./$(BIN)

# Sanitizer builds (skills: sanitizers, concurrency-debugging) — separate binaries so they
# don't clobber ./dictate. TSan catches data races on the worker/cancel paths; ASan+UBSan
# catch memory errors and UB. Exercise without a mic via:  ./dictate-tsan --file /tmp/t.wav
tsan: $(SRC) Makefile
	$(CXX) $(CXXFLAGS) -fsanitize=thread -g $(SRC) -o $(BIN)-tsan $(LDFLAGS)

asan: $(SRC) Makefile
	$(CXX) $(CXXFLAGS) -fsanitize=address,undefined -fno-omit-frame-pointer -g $(SRC) -o $(BIN)-asan $(LDFLAGS)

# Static analysis (skill: static-analysis) — clang-tidy reads the build flags after `--`.
tidy: $(SRC)
	clang-tidy $(SRC) -- $(CXXFLAGS)

# ── Unit tests (doctest; skill: cpp-testing) ─────────────────────────────────────
# Compiles the pure-logic units extracted into src/dictate_*.h against the doctest
# harness. Deliberately links NO whisper/ggml/AVFoundation/AppKit — the tested logic is
# platform-independent C++/POSIX, so `make test` runs anywhere with a C++17 compiler
# (clang++ on macOS, g++ on Linux via the default `c++`). The full src/dictate.mm macOS
# build is NOT exercised here; keep using `make` + `make tsan|asan` on a Mac for that, and
# `--file`/`feedfile` as e2e for the whisper/mic paths (gotcha #19).
TEST_CXX    ?= c++
TEST_BIN    := tests/run
TEST_SRCS   := $(wildcard tests/*.cpp)
TEST_CXXFLAGS := -std=c++17 -O0 -g -Wall -Wextra -Wshadow -pthread -I src -I tests

test:
	$(TEST_CXX) $(TEST_CXXFLAGS) $(TEST_SRCS) -o $(TEST_BIN)
	./$(TEST_BIN)

clean:
	rm -f $(BIN) $(BIN)-tsan $(BIN)-asan $(TEST_BIN)
	rm -rf $(BIN).dSYM $(BIN)-tsan.dSYM $(BIN)-asan.dSYM

.PHONY: run clean tsan asan tidy test
