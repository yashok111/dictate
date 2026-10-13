#!/bin/bash
# Requires a macOS GUI session and the libraries built by test-swift.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/layout
# Compile the real views, without the production entry point or library path.
sed '/^@main$/d' Sources/TranscriberApp/TranscriberApp.swift >build/layout/Regression.swift
cat tests/swift/LayoutRegression.swift >>build/layout/Regression.swift
swiftc -swift-version 5 -parse-as-library \
  -I core/include -I build/swift -L build/swift -lTranscriptKit \
  -Xlinker -rpath -Xlinker "$PWD/build/swift" \
  Sources/TranscriberApp/LibraryController.swift \
  Sources/TranscriberApp/RuntimeConfiguration.swift \
  Sources/TranscriberApp/ModelsController.swift \
  Sources/TranscriberApp/ModelsView.swift \
  Sources/TranscriberApp/MeetingContextView.swift \
  Sources/TranscriberApp/ApplicationLifecycle.swift \
  Sources/TranscriberApp/LibraryWelcomeView.swift \
  Sources/TranscriberApp/TranscriptTimeline.swift \
  Sources/TranscriberApp/SearchHighlightedText.swift \
  Sources/TranscriberApp/GlassAppearance.swift \
  Sources/TranscriberApp/MotionAppearance.swift \
  build/layout/Regression.swift -o build/layout/regression
build/layout/regression
