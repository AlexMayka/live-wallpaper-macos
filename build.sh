#!/bin/bash
set -euo pipefail

if (( $# > 1 )); then
    printf 'Использование: %s [путь к видео MP4 или MOV]\n' "$0" >&2
    exit 2
fi

video_path=${1:-}
video_extension=
if [[ -n "$video_path" ]]; then
    if [[ ! -f "$video_path" || ! -r "$video_path" ]]; then
        printf 'Не удалось открыть видео: %s\n' "$video_path" >&2
        exit 2
    fi

    # Превращаем относительный путь в абсолютный до перехода в каталог проекта.
    [[ "$video_path" = /* ]] || video_path="$PWD/$video_path"
    case "$video_path" in
        *.[mM][pP]4) video_extension=mp4 ;;
        *.[mM][oO][vV]) video_extension=mov ;;
        *) printf 'Для встроенного видео нужен файл MP4 или MOV.\n' >&2; exit 2 ;;
    esac
fi

cd "$(dirname "${BASH_SOURCE[0]}")"
mkdir -p dist
staging=$(mktemp -d "$PWD/dist/.build.XXXXXX")
trap 'rm -rf "$staging"' EXIT
bundle="$staging/Живые обои.app"
destination="$PWD/dist/Живые обои.app"

mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp Info.plist "$bundle/Contents/Info.plist"
cp Resources/Wallpaper.icns "$bundle/Contents/Resources/Wallpaper.icns"
if [[ -n "$video_path" ]]; then
    cp "$video_path" "$bundle/Contents/Resources/DefaultWallpaper.$video_extension"
fi

arch=$(uname -m)
xcrun swiftc -swift-version 6 -O -parse-as-library \
    -target "$arch-apple-macos14.0" \
    -module-cache-path "$staging/module-cache" \
    Source/*.swift -o "$bundle/Contents/MacOS/LiveWallpaper"
/usr/bin/codesign --force --sign - "$bundle"
/usr/bin/codesign --verify --strict "$bundle"

if [[ -e "$destination" ]]; then
    mv "$destination" "$staging/previous.app"
fi
if ! mv "$bundle" "$destination"; then
    if [[ -e "$staging/previous.app" ]]; then
        mv "$staging/previous.app" "$destination"
    fi
    exit 1
fi
printf '%s\n' "$destination"
