#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd -P)"
version="${1:-0.1.0}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]]; then
    echo "版本号格式不正确：$version" >&2
    exit 1
fi

build="$root/build"
dist="$root/dist"
release="$build/WeChatDownloadSync-v$version"
app="$release/WeChatDownloadSync.app"
mkdir -p "$build/module-cache" "$dist"
rm -rf "$release"
mkdir -p "$app/Contents/MacOS"

for arch in arm64 x86_64; do
    xcrun swiftc -O -module-cache-path "$build/module-cache" \
        -target "$arch-apple-macos13.0" "$root/main.swift" -o "$build/WeChatDownloadSync-$arch"
done
xcrun lipo -create "$build/WeChatDownloadSync-arm64" "$build/WeChatDownloadSync-x86_64" \
    -output "$app/Contents/MacOS/WeChatDownloadSync"
cp "$root/Info.plist" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$app/Contents/Info.plist"
codesign --force --sign - --entitlements "$root/entitlements.plist" "$app"
codesign --verify --strict "$app"

cp "$root/Install.command" "$root/Uninstall.command" "$root/README.md" "$root/LICENSE" "$release/"
chmod +x "$release/Install.command" "$release/Uninstall.command"
archive="$dist/WeChatDownloadSync-v$version-macOS.zip"
rm -f "$archive"
ditto -c -k --norsrc --noextattr --noqtn --noacl --keepParent "$release" "$archive"
(cd "$dist" && shasum -a 256 "$(basename "$archive")" > "$(basename "$archive").sha256")
echo "构建完成：$archive"
