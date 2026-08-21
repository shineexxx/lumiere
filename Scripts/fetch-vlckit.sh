#!/bin/bash
# Кладёт VLCKit.xcframework в Frameworks/ — без него проект не соберётся.
# В git фреймворк не хранится: 543 МБ, отдельные файлы больше лимита GitHub.
set -euo pipefail

ARCHIVE_URL="https://artifacts.videolan.org/VLCKit/dev-artifacts-VLCKit/VLCKit-4.0-20260629-1420.tar.xz"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="$ROOT/Frameworks/VLCKit.xcframework"

if [ -d "$TARGET" ]; then
  echo "VLCKit уже на месте: $TARGET"
  exit 0
fi

TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT

echo "Качаю VLCKit (~540 МБ), это надолго…"
curl -fL --progress-bar "$ARCHIVE_URL" -o "$TEMP/vlckit.tar.xz"

echo "Распаковываю…"
tar -xJf "$TEMP/vlckit.tar.xz" -C "$TEMP"

FOUND="$(find "$TEMP" -maxdepth 3 -name 'VLCKit.xcframework' -type d | head -1)"
if [ -z "$FOUND" ]; then
  echo "В архиве нет VLCKit.xcframework — проверьте ссылку" >&2
  exit 1
fi

mkdir -p "$ROOT/Frameworks"
mv "$FOUND" "$TARGET"
echo "Готово: $TARGET"
