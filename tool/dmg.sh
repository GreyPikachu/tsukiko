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

# Том с таким же именем уже смонтирован — беда тихая и злая.
#
# Раскладку окна наводит AppleScript, и обращается он к тому по имени:
# `disk "tsukiko"`. Если такой том уже есть — открытый прошлый образ,
# забытая проверка, — то новый монтируется как «tsukiko 1», а скрипт
# спокойно раскладывает окно у старого. Собранный образ выходит без
# раскладки вовсе: ни фона, ни расставленных значков, ни размера окна.
# Снаружи это выглядит как «установщик полетел», и по самому образу
# причины не видно.
if [ -d "/Volumes/$VOLUME" ]; then
  echo "Отсоединяю уже смонтированный /Volumes/$VOLUME"
  hdiutil detach "/Volumes/$VOLUME" -force >/dev/null
fi

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

# Куда образ встал, спрашиваем у него самого, а не додумываем: имя тома
# могли занять между проверкой выше и этой строкой, а раскладывать
# вслепую — это ровно та беда, от которой мы только что закрылись.
ATTACHED=$(hdiutil attach -readwrite -noverify -noautoopen build/tsukiko-rw.dmg)
DEV=$(printf '%s\n' "$ATTACHED" | awk '/\/dev\/disk/ {print $1; exit}')
MOUNT=$(printf '%s\n' "$ATTACHED" | sed -n 's|.*\(/Volumes/.*\)$|\1|p' | tail -1)

if [ "$MOUNT" != "/Volumes/$VOLUME" ]; then
  echo "Образ встал в «$MOUNT», а не в «/Volumes/$VOLUME»: раскладку" >&2
  echo "наводить нечему — AppleScript ищет том по имени." >&2
  hdiutil detach "$DEV" >/dev/null
  exit 1
fi

# Раскладка окна: приложение слева, «Программы» справа, между ними —
# то расстояние, которое читается как жест перетаскивания.
# Без `|| true`: молча пропущенная раскладка и есть тот самый образ
# без фона, который потом никто не может объяснить. В CI делаем предупреждение.
if ! osascript <<APPLESCRIPT >/dev/null
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
    -- tool/dmg-background.py по этим же числам. Finder кладёт значки
    -- на 27 точек ниже, чем просят (высота титульной полосы), и гнёзда
    -- на фоне нарисованы с этой поправкой.
    set position of item "tsukiko.app" of container window to {150, 190}
    set position of item "Applications" of container window to {450, 190}
    close
    open
    update without registering applications
    delay 1
  end tell
end tell
APPLESCRIPT
then
  echo "::warning::Не удалось применить раскладку окна через AppleScript в Finder" >&2
  [ -n "$CI" ] || exit 1
fi

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
