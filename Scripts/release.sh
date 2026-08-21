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

# Подписываем ДО упаковки, и обязательно с --deep.
# Xcode подписывает ad-hoc только сам бандл, а вложенный VLCKit остаётся с
# подписью VideoLAN. Для dyld это разные Team ID, и он отказывается грузить
# фреймворк: приложение из dmg падало при запуске ещё до первой строки кода.
echo "Подписываю…"
codesign --force --deep --sign - "$APP"
codesign -v "$APP" || { echo "Подпись не прошла проверку" >&2; exit 1; }

echo "Ставлю в /Applications…"
osascript -e 'tell application "Lumiere" to quit' 2>/dev/null || true
sleep 2
rm -rf /Applications/Lumiere.app
ditto "$APP" /Applications/Lumiere.app

echo "Пакую zip…"
ZIP="/tmp/Lumiere-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

echo "Собираю dmg…"
DMG="/tmp/Lumiere-$VERSION.dmg"
STAGE="$(mktemp -d)"
ditto "$APP" "$STAGE/Lumiere.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Lumière $VERSION" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGE"

echo "Публикую релиз $TAG…"
if [ -n "$NOTES" ]; then
  gh release create "$TAG" "$DMG" "$ZIP" --title "Lumière $VERSION" --notes "$NOTES"
else
  gh release create "$TAG" "$DMG" "$ZIP" --title "Lumière $VERSION" --generate-notes
fi

# Cask в отдельном репозитории-тапе: обновляем версию и контрольную сумму,
# иначе «brew install --cask» будет ставить прошлый релиз.
TAP="${LUMIERE_TAP:-$HOME/Projects/homebrew-lumiere}"
if [ -d "$TAP/.git" ]; then
  echo "Обновляю cask…"
  SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
  /usr/bin/sed -i '' -E "s/^  version \".*\"$/  version \"$VERSION\"/" "$TAP/Casks/lumiere.rb"
  /usr/bin/sed -i '' -E "s/^  sha256 .*$/  sha256 \"$SHA\"/" "$TAP/Casks/lumiere.rb"
  git -C "$TAP" add -A
  git -C "$TAP" commit -q -m "Lumière $VERSION" && git -C "$TAP" push -q origin main
  echo "Cask обновлён: $VERSION / ${SHA:0:12}…"
else
  echo "Тап не найден в $TAP — cask не обновлён" >&2
fi

echo "Готово: $(gh release view "$TAG" --json url --jq .url)"
