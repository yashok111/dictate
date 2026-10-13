#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mode=development
if [[ ${1:-} == --mode ]]; then
	mode=${2:?Missing mode}
	shift 2
fi
[[ $# == 0 && ($mode == development || $mode == release) ]] || {
	echo 'Usage: build-app.sh [--mode development|release]' >&2
	exit 2
}
if [[ $mode == release ]]; then make release-worker; else make worker; fi
bash scripts/test-swift.sh
bash scripts/test-community-contract.sh
bash scripts/build-community-1.sh
bash scripts/build-icon.sh
staging=$(mktemp -d "$PWD/build/app-staging.XXXXXX")
trap 'rm -rf "$staging"' EXIT
app="$staging/Transcriber.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Frameworks"
swiftc -target arm64-apple-macosx26.0 -swift-version 5 -parse-as-library -I core/include -I build/swift -L build/swift -lTranscriptKit \
	-Xlinker -rpath -Xlinker @executable_path/../Frameworks \
	Sources/TranscriberApp/*.swift -o "$app/Contents/MacOS/Transcriber"
cp build/swift/libTranscriptKit.dylib build/swift/libCTranscriber.dylib "$app/Contents/Frameworks/"
cp build/AppIcon.icns "$app/Contents/Resources/"
python3 scripts/write-bundle.py "$app" --mode "$mode"
if [[ $mode == release ]]; then
    ditto build/community-1 "$app/Contents/Helpers"
	python3 scripts/bundle-runtime.py "$app" build/release/transcriber-worker "$(brew --prefix ggml)/libexec"
	cp -R Resources/ThirdPartyNotices "$app/Contents/Resources/"
	python3 scripts/audit-bundle.py "$app"
else
    ditto build/community-1 "$app/Contents/Resources"
	cp build/transcriber-worker "$app/Contents/Resources/"
fi
bash scripts/sign-app.sh "$app" --mode adhoc
destination=build/Transcriber.app
if [[ $mode == release ]]; then destination=build/release/Transcriber.app; fi
# Move the new app next to the destination first, then swap: if anything fails between the two
# moves, the previous app is put back instead of being deleted with the staging directory.
mkdir -p "$(dirname "$destination")"
mv "$app" "$destination.new"
if [[ -e $destination ]]; then mv "$destination" "$staging/previous.app"; fi
if ! mv "$destination.new" "$destination"; then
	[[ -e $staging/previous.app ]] && mv "$staging/previous.app" "$destination"
	echo "Could not install $destination; the previous build is kept" >&2
	exit 1
fi
printf 'Built: %s/%s\n' "$PWD" "$destination"
