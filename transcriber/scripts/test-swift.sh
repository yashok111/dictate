#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/swift
mkdir -p build/swift/test-bundle/Contents/Resources
python3 scripts/write-bundle.py build/swift/test-bundle
clang++ -std=c++17 -dynamiclib core/c_api.cpp -Wl,-install_name,@rpath/libCTranscriber.dylib -o build/swift/libCTranscriber.dylib
swiftc -swift-version 5 -emit-library -emit-module -enable-testing \
  -I core/include -L build/swift -lCTranscriber -Xlinker -rpath -Xlinker "$PWD/build/swift" \
  -module-name TranscriptKit Sources/TranscriptKit/*.swift \
  -emit-module-path build/swift/TranscriptKit.swiftmodule -o build/swift/libTranscriptKit.dylib \
  -Xlinker -install_name -Xlinker @rpath/libTranscriptKit.dylib -Xlinker -rpath -Xlinker @loader_path
swiftc -swift-version 5 -I core/include -I build/swift -L build/swift -lTranscriptKit \
  -Xlinker -rpath -Xlinker "$PWD/build/swift" \
  Sources/TranscriberApp/RuntimeConfiguration.swift Sources/TranscriberApp/ModelsController.swift \
  Sources/TranscriberApp/LibraryController.swift tests/TranscriptKitTests/*.swift tests/swift/main.swift -o build/swift/tests
build/swift/tests
