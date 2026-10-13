#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mode=adhoc
notarize=false
app=
while [[ $# -gt 0 ]]; do
	case "$1" in
	--mode)
		mode=${2:?Missing signing mode}
		shift 2
		;;
	--app)
		app=${2:?Missing app path}
		shift 2
		;;
	--notarize)
		notarize=true
		shift
		;;
	*)
		echo "Unknown option: $1" >&2
		exit 2
		;;
	esac
done
case "$mode" in
adhoc) ;;
developer-id) : "${TRANSCRIBER_SIGN_IDENTITY:?Set TRANSCRIBER_SIGN_IDENTITY}" ;;
*)
	echo 'Expected adhoc or developer-id' >&2
	exit 2
	;;
esac
if $notarize; then
	[[ $mode == developer-id ]] || {
		echo 'Notarization requires developer-id mode' >&2
		exit 2
	}
	: "${TRANSCRIBER_NOTARY_PROFILE:?Set TRANSCRIBER_NOTARY_PROFILE}"
fi
if [[ -z $app ]]; then
	bash scripts/build-app.sh --mode release
	app="$PWD/build/release/Transcriber.app"
fi
python3 scripts/audit-bundle.py "$app"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
	echo 'Invalid release version' >&2
	exit 2
}
mkdir -p build
staging=$(mktemp -d "$PWD/build/dmg-staging.XXXXXX")
mounted=false
cleanup() {
	if $mounted; then
		# Keep the staging directory if detach fails: never remove a mounted volume.
		hdiutil detach "$staging/mount" || return 1
	fi
	rm -rf "$staging"
}
trap cleanup EXIT
mkdir "$staging/volume"
ditto "$app" "$staging/volume/Transcriber.app"
ln -s /Applications "$staging/volume/Applications"
bash scripts/sign-app.sh "$staging/volume/Transcriber.app" --mode "$mode"
if $notarize; then
	ditto -c -k --keepParent "$staging/volume/Transcriber.app" "$staging/app.zip"
	xcrun notarytool submit "$staging/app.zip" --keychain-profile "$TRANSCRIBER_NOTARY_PROFILE" --wait
	xcrun stapler staple "$staging/volume/Transcriber.app"
	xcrun stapler validate "$staging/volume/Transcriber.app"
fi
output="Transcriber-$version-arm64.dmg"
mkdir "$staging/volume/.background"
swift scripts/draw-dmg-background.swift "$staging/volume/.background/installer.tiff"
# Finder writes window geometry, icon positions and the volume-relative
# background alias into .DS_Store before the read-only image is compressed.
hdiutil create -volname Transcriber -fs HFS+ -srcfolder "$staging/volume" -format UDRW "$staging/writable.dmg"
mkdir "$staging/mount"
hdiutil attach "$staging/writable.dmg" -mountpoint "$staging/mount" -nobrowse -noautoopen
mounted=true
osascript scripts/layout-dmg.applescript "$staging/mount"
# Finder may flush its folder settings asynchronously after the window closes.
for ((attempt = 0; attempt < 10; attempt++)); do
	[[ -s $staging/mount/.DS_Store ]] && break
	sleep 1
done
[[ -s $staging/mount/.DS_Store ]] || {
	echo 'Finder did not save the DMG layout' >&2
	exit 1
}
sync
hdiutil detach "$staging/mount"
mounted=false
hdiutil convert "$staging/writable.dmg" -format UDZO -o "$staging/$output"
if [[ $mode == developer-id ]]; then
	codesign --force --timestamp --sign "$TRANSCRIBER_SIGN_IDENTITY" "$staging/$output"
fi
if $notarize; then
	xcrun notarytool submit "$staging/$output" --keychain-profile "$TRANSCRIBER_NOTARY_PROFILE" --wait
	xcrun stapler staple "$staging/$output"
	xcrun stapler validate "$staging/$output"
fi
hdiutil verify "$staging/$output"
mv -f "$staging/$output" "build/$output"
shasum -a 256 "build/$output"
printf 'DMG: %s/build/%s (%s)\n' "$PWD" "$output" "$mode"
