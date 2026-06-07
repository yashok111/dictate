#!/usr/bin/env bash
# Install curated agent skills for the `dictate` repo into .claude/skills/.
# Non-interactive: passes -y and targets the `claude-code` agent, so files land
# in <repo>/.claude/skills/ — exactly where Claude Code auto-discovers them.
# Re-run after a fresh clone to repopulate (lockfile: skills-lock.json).
#
# NB — agent target differs from the sibling Telega script on purpose. Telega
# installs to the `universal` agent (.agents/skills/) as a cross-agent library
# and symlinks a few into .claude/skills/. Here the whole point is that *this*
# Claude Code loads the skills while working ON dictate, so we install straight
# to .claude/skills/ (the only dir Claude Code reads natively). Override with
# DICTATE_SKILLS_AGENT=universal if you want the Telega-style library location.
#
# Stack this curates for: native macOS push-to-talk dictation in Objective-C++
# (src/dictate.mm) — AVFoundation mic capture, whisper.cpp/libwhisper on Metal,
# NSPasteboard, a resident Unix-socket daemon (fork+setsid+exec), and a
# realtime audio tap feeding a single whisper worker thread. Built with a
# Makefile + clang++ against Homebrew whisper-cpp/ggml. No Swift, no Xcode.
#
# Usage (run from anywhere):
#   bash scripts/install-skills.sh                 # install everything
#   bash scripts/install-skills.sh --dry-run       # print commands only
#   bash scripts/install-skills.sh superpowers
#   bash scripts/install-skills.sh han
#   bash scripts/install-skills.sh lowlevel
#   bash scripts/install-skills.sh ecc
#   bash scripts/install-skills.sh anthropics

set -euo pipefail

REPO_SUPERPOWERS="https://github.com/obra/superpowers"
REPO_HAN="https://github.com/thebushidocollective/han"
REPO_LOWLEVEL="https://github.com/mohitmishra786/low-level-dev-skills"
REPO_ECC="https://github.com/affaan-m/everything-claude-code"
REPO_ANTHROPICS="https://github.com/anthropics/skills"

AGENT="${DICTATE_SKILLS_AGENT:-claude-code}"

# Language-agnostic workflow discipline: plan → TDD → debug to root cause →
# verify before claiming done → review. Useful on any change to dictate.
SUPERPOWERS_SKILLS=(
  writing-plans
  executing-plans
  test-driven-development
  systematic-debugging
  verification-before-completion
  requesting-code-review
  receiving-code-review
  brainstorming
)

# The core ask: C / C++ / Objective-C language skills. dictate.mm is
# Objective-C++ — ObjC for the AVFoundation/Cocoa side, C++ for the
# whisper.cpp/STL/threading side, C for the socket+daemon plumbing.
# Note: the Objective-C skills declare a Title-Case `name:` (the skills CLI
# matches --skill on the SKILL.md `name:` field, NOT the folder slug), so they
# are passed verbatim with spaces; install_set quotes them correctly.
#   - ARC Patterns / retain cycles  → the AVAudioEngine tap block captures self
#   - Blocks and GCD                → tap callback + dispatch on the audio path
#   - smart-pointers / RAII         → owning g_ctx / g_sess / g_rec lifetimes
#   - c-systems-programming         → Unix socket, fork/setsid/exec, fds, signals
HAN_SKILLS=(
  "Objective-C ARC Patterns"
  "Objective-C Blocks and GCD"
  "Objective-C Protocols and Categories"
  cpp-modern-features
  cpp-smart-pointers
  cpp-templates-metaprogramming
  c-systems-programming
  c-memory-management
)

# Toolchain / debugging / perf — macOS-portable subset of a Linux-leaning set.
# Skipped on purpose (Linux/Intel-only or unused here): gdb (lldb is the macOS
# debugger), valgrind (poor arm64-macOS support), linux-perf / ebpf /
# strace-ltrace / elf-inspection (Mach-O, not ELF), ninja/meson/bazel (we use
# make), conan-vcpkg (we use Homebrew).
#   - clang / make / cmake   → our compiler + Makefile; deps (whisper.cpp, ggml)
#                              are CMake projects
#   - lldb                   → macOS debugger; covers Objective-C AND C++
#   - sanitizers (ASan/UBSan/TSan) + concurrency-debugging + memory-model
#                            → directly target the hard gotchas: whisper_context
#                              is NOT thread-safe, the tap runs on a realtime
#                              thread, std::atomic ordering in StreamingSession
#   - simd-intrinsics        → NEON for the VAD energy math on the hot tap path
#   - dynamic-linking        → ggml backends load at runtime from libexec (the
#                              dlopen/plugin gotcha #1)
#   - static-analysis / flamegraphs / build-acceleration → review + latency work
LOWLEVEL_SKILLS=(
  clang
  make
  cmake
  lldb
  sanitizers
  concurrency-debugging
  memory-model
  simd-intrinsics
  static-analysis
  flamegraphs
  build-acceleration
  dynamic-linking
)

# C++ standards/testing + realtime + general engineering.
#   - cpp-coding-standards   → C++ Core Guidelines (isocpp) enforcement
#   - cpp-testing            → GoogleTest/CTest + sanitizers wiring
#   - latency-critical-systems → low-latency / p95 discipline for the audio path
ECC_SKILLS=(
  cpp-coding-standards
  cpp-testing
  latency-critical-systems
  search-first
  documentation-lookup
  codebase-onboarding
  safety-guard
  security-review
)

# Anthropic-canonical: author dictate-specific skills later (e.g. encode the
# CRITICAL GOTCHAS as a skill).
ANTHROPICS_SKILLS=(
  skill-creator
)

DRY_RUN=0
TARGETS=(
  "superpowers"
  "han"
  "lowlevel"
  "ecc"
  "anthropics"
)
SELECTED=()

for arg in "$@"; do
  case "$arg" in
    --dry-run|-n) DRY_RUN=1 ;;
    superpowers|han|lowlevel|ecc|anthropics)
      SELECTED+=("$arg")
      ;;
    -h|--help)
      sed -n '2,27p' "$0"
      exit 0
      ;;
    *)
      echo "unknown arg: $arg" >&2
      exit 2
      ;;
  esac
done

if [[ ${#SELECTED[@]} -gt 0 ]]; then
  TARGETS=("${SELECTED[@]}")
fi

run() {
  local q=""
  for a in "$@"; do
    if [[ "$a" == *" "* ]]; then
      q+=" \"$a\""
    else
      q+=" $a"
    fi
  done
  echo "+${q}"
  if [[ $DRY_RUN -eq 0 ]]; then
    "$@"
  fi
}

install_set() {
  local repo="$1"
  shift
  local -a skills=("$@")
  echo
  echo "=== $repo (${#skills[@]} skills) → agent: $AGENT ==="
  # -y skips prompts; -a <agent> pins where skills land (.claude/skills/ for
  # claude-code). --skill matches each SKILL.md `name:` field (spaces ok).
  # SUPPLY CHAIN: `npx -y -p skills` fetches+runs the `skills` package unpinned, and the
  # repos above are third-party. This runs arbitrary code as you — only run it for sources
  # you trust. To harden, pin the package (e.g. `-p skills@X.Y.Z`) and the repos to a commit.
  run npx -y -p skills skills add "$repo" -y -a "$AGENT" --skill "${skills[@]}"
}

cd "$(dirname "$0")/.."  # cwd → repo root (skills land in .claude/skills/)

for t in "${TARGETS[@]}"; do
  case "$t" in
    superpowers) install_set "$REPO_SUPERPOWERS" "${SUPERPOWERS_SKILLS[@]}" ;;
    han)         install_set "$REPO_HAN"         "${HAN_SKILLS[@]}" ;;
    lowlevel)    install_set "$REPO_LOWLEVEL"    "${LOWLEVEL_SKILLS[@]}" ;;
    ecc)         install_set "$REPO_ECC"         "${ECC_SKILLS[@]}" ;;
    anthropics)  install_set "$REPO_ANTHROPICS"  "${ANTHROPICS_SKILLS[@]}" ;;
  esac
done

echo
echo "done. skills in .claude/skills/. lockfile: skills-lock.json"
