#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app=${1:?Usage: test-release.sh ABSOLUTE_APP_PATH}
python3 scripts/audit-bundle.py "$app"
codesign --verify --deep --strict "$app"
test_root=$(mktemp -d /private/tmp/transcriber-release-check.XXXXXX)
relocated="$test_root/Проверка Transcriber.app"
ditto "$app" "$relocated"
say -v Milena -o "$test_root/source.aiff" 'Сегодня мы проверяем приложение для расшифровки встреч. Все модели работают на этом компьютере.'
swiftc -swift-version 5 -parse-as-library -I core/include -I build/swift \
	-L "$relocated/Contents/Frameworks" -lTranscriptKit \
	-Xlinker -rpath -Xlinker "$relocated/Contents/Frameworks" \
	Sources/TranscriberApp/RuntimeConfiguration.swift Sources/TranscriberApp/ModelsController.swift \
	Sources/TranscriberApp/LibraryController.swift tests/swift/ReleaseSmoke.swift -o "$test_root/release-smoke"
"$test_root/release-smoke" "$relocated" "$test_root" "$test_root/source.aiff"
