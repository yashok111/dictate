#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -swift-version 5 Sources/CommunityDiarizer/{PreparedInput,TurnOutput,SpeakerCache,ReidentificationPolicy}.swift \
 tests/CommunityDiarizerTests/main.swift -o build/test-community-contract
build/test-community-contract
