#!/bin/sh
# Собрать .dmg, который открывается окном «перетащите tsukiko в Программы».
#
# Зачем так, а не просто файл: приложение, запущенное из папки загрузок,
# macOS переносит в случайное место (app translocation) — и выданный ему
# «Универсальный доступ» перестаёт действовать при каждом запуске.
# Перетаскивание в «Программы» — не украшение, а условие работы диктовки.
#
# Запускать после `flutter build macos --release` и `./tool/sign.sh`.
set -e
cd "$(dirname "$0")/.."

APP=build/macos/Build/Products/Release/tsukiko.app
OUT=build/tsukiko.dmg
STAGE=build/dmg-stage
VOLUME="tsukiko"

[ -d "$APP" ] || {
  echo "Нет собранного приложения. Сначала: flutter build macos --release && ./tool/sign.sh" >&2
  exit 1
}

# Подпись обязана быть на месте: dmg её не чинит, а только упаковывает.
codesign -v --deep --strict "$APP" || {
  echo "Приложение не подписано. Сначала ./tool/sign.sh" >&2
  exit 1
}

BACKGROUND=design/dmg-background.tiff
[ -f "$BACKGROUND" ] || {
  echo "Нет фона окна. Нарисовать: python3 tool/dmg-background.py" >&2
  exit 1
}

rm -rf "$STAGE" "$OUT" build/tsukiko-rw.dmg
mkdir -p "$STAGE/.background"
# Точка в начале имени прячет папку: в окне образа должны быть видны
# ровно две вещи — приложение и «Программы».
cp "$BACKGROUND" "$STAGE/.background/background.tiff"
cp -R "$APP" "$STAGE/"
# Та самая стрелка «сюда»: папка «Программы» лежит рядом ссылкой, и
# перетаскивание внутри окна и есть установка.
ln -s /Applications "$STAGE/Applications"

# Сначала образ, в который можно писать: расстановку значков Finder
# хранит в самом образе, и на «только чтение» её не записать.
hdiutil create -srcfolder "$STAGE" -volname "$VOLUME" -fs HFS+ \
  -format UDRW -ov build/tsukiko-rw.dmg >/dev/null

DEV=$(hdiutil attach -readwrite -noverify -noautoopen build/tsukiko-rw.dmg |
  awk '/\/dev\/disk/ {print $1; exit}')
MOUNT="/Volumes/$VOLUME"

# Раскладка окна: приложение слева, «Программы» справа, между ними —
# то расстояние, которое читается как жест перетаскивания.
osascript <<APPLESCRIPT >/dev/null || true
tell application "Finder"
  tell disk "$VOLUME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 140, 800, 540}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 96
    set text size of viewOptions to 12
    set background picture of viewOptions to file ".background:background.tiff"
    -- Координаты обязаны совпадать с гнёздами на фоне: их рисует
    -- tool/dmg-background.py по этим же числам.
    set position of item "tsukiko.app" of container window to {150, 190}
    set position of item "Applications" of container window to {450, 190}
    close
    open
    update without registering applications
    delay 1
  end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$DEV" >/dev/null
# Сжатый образ только для чтения — таким его и раздают.
hdiutil convert build/tsukiko-rw.dmg -format UDZO -imagekey zlib-level=9 \
  -o "$OUT" >/dev/null
rm -f build/tsukiko-rw.dmg
rm -rf "$STAGE"

codesign --force --sign "$(security find-identity -v -p codesigning | awk 'NR==1 {print $2}')" \
  --timestamp=none "$OUT" 2>/dev/null || true

echo "готово: $OUT ($(du -h "$OUT" | cut -f1))"
