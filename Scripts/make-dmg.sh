#!/bin/bash
# Собирает оформленный образ: фон, размер окна, положение и размер иконок.
# Простой `hdiutil create` даёт голое окно со списком файлов — то, что видно
# при первом открытии, стоит того, чтобы настроить его один раз.
#
#   Scripts/make-dmg.sh <путь к .app> <версия> <куда положить .dmg>
set -euo pipefail

APP="${1:?нужен путь к .app}"
VERSION="${2:?нужна версия}"
OUTPUT="${3:?нужен путь к итоговому dmg}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BACKGROUND="$ROOT/docs/dmg-background.png"
VOLUME="Lumière $VERSION"
STAGE="$(mktemp -d)"
TEMP_DMG="$(mktemp -u).dmg"
trap 'rm -rf "$STAGE" "$TEMP_DMG"' EXIT

# Содержимое: приложение, ярлык «Программ» и скрытая папка с фоном.
ditto "$APP" "$STAGE/Lumiere.app"
ln -s /Applications "$STAGE/Applications"
mkdir "$STAGE/.background"
cp "$BACKGROUND" "$STAGE/.background/background.png"

# Пишущий образ: только в нём Finder может сохранить вид окна.
SIZE_MB=$(( $(du -sm "$STAGE" | cut -f1) + 60 ))
hdiutil create -srcfolder "$STAGE" -volname "$VOLUME" -fs HFS+ \
  -format UDRW -size "${SIZE_MB}m" -ov -quiet "$TEMP_DMG"

MOUNT="/Volumes/$VOLUME"
hdiutil attach "$TEMP_DMG" -readwrite -noverify -noautoopen -quiet
sleep 2

# Раскладку окна умеет сохранять только Finder — отсюда AppleScript.
# Если системе не разрешено управлять Finder, оформление пропускаем:
# образ должен собираться в любом случае, пусть и без фона.
STYLED=1
osascript <<APPLESCRIPT || STYLED=0
tell application "Finder"
  tell disk "$VOLUME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    -- Кадр: 640 в ширину, плюс высота заголовка и полосы состояния к 400 видимым.
    set the bounds of container window to {200, 140, 840, 592}
    set options to the icon view options of container window
    set arrangement of options to not arranged
    set icon size of options to 116
    set text size of options to 12
    set background picture of options to file ".background:background.png"
    set position of item "Lumiere.app" of container window to {170, 205}
    set position of item "Applications" of container window to {470, 205}
    close
    open
    -- Полоса состояния и панель инструментов возвращаются при повторном открытии,
    -- поэтому гасим их ещё раз — уже на открытом окне.
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    update without registering applications
    delay 2
    close
  end tell
end tell
APPLESCRIPT

if [ "$STYLED" = "0" ]; then
  echo "Не удалось оформить окно образа: системе не разрешено управлять Finder." >&2
  echo "Разрешение: Системные настройки → Конфиденциальность и безопасность → Автоматизация." >&2
fi

sync
hdiutil detach "$MOUNT" -quiet -force
sleep 1

# Сжатый образ только для чтения — то, что уходит в релиз.
rm -f "$OUTPUT"
hdiutil convert "$TEMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$OUTPUT" -quiet
echo "образ готов: $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
