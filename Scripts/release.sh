#!/bin/bash
# Собирает Release, кладёт приложение в /Applications и публикует релиз на GitHub.
# Версию берём из проекта — та же, с которой приложение сравнивает себя при проверке обновлений.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(grep -m1 'MARKETING_VERSION' VideoClient.xcodeproj/project.pbxproj | sed 's/[^0-9.]//g')"
TAG="v$VERSION"
NOTES="${1:-}"

echo "Собираю $TAG…"
xcodebuild -project VideoClient.xcodeproj -scheme VideoClient -configuration Release \
  -derivedDataPath build > /tmp/lumiere-build.log 2>&1 || { tail -30 /tmp/lumiere-build.log; exit 1; }

APP="build/Build/Products/Release/Lumiere.app"
[ -d "$APP" ] || { echo "Сборка не нашлась: $APP" >&2; exit 1; }

echo "Ставлю в /Applications…"
osascript -e 'tell application "Lumiere" to quit' 2>/dev/null || true
sleep 2
rm -rf /Applications/Lumiere.app
ditto "$APP" /Applications/Lumiere.app
codesign --force --deep --sign - /Applications/Lumiere.app

echo "Пакую…"
ZIP="/tmp/Lumiere-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "Публикую релиз $TAG…"
if [ -n "$NOTES" ]; then
  gh release create "$TAG" "$ZIP" --title "Lumière $VERSION" --notes "$NOTES"
else
  gh release create "$TAG" "$ZIP" --title "Lumière $VERSION" --generate-notes
fi

echo "Готово: $(gh release view "$TAG" --json url --jq .url)"
