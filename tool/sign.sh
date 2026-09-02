#!/bin/sh
# Подписать собранное приложение постоянной подписью разработчика.
#
# Зачем: macOS привязывает выданное разрешение («Универсальный доступ»)
# к подписи приложения. Flutter собирает с ad-hoc
# подписью, а её отпечаток меняется с каждой сборкой — выданное разрешение
# после пересборки перестаёт действовать, и диктовка молча замолкает.
# Подпись сертификатом из связки ключей одна и та же от сборки к сборке,
# поэтому разрешение выдаётся один раз.
#
# Заодно кладёт внутрь движок whisper.cpp — его надо собрать заранее,
# один раз: ./tool/engine.sh
#
# Запускать после `flutter build macos --release`.
set -e
cd "$(dirname "$0")/.."

APP=build/macos/Build/Products/Release/tsukiko.app
ID=$(security find-identity -v -p codesigning | awk 'NR==1 {print $2}')
if [ -z "$ID" ]; then
  echo "Нет сертификата для подписи кода. Xcode → Settings → Accounts." >&2
  exit 1
fi

# Движок едет внутри приложения: у всех один и тот же, не зависит от того,
# что стоит у человека в системе, и не пропадает, если он снесёт Homebrew.
# Собирается отдельно — tool/engine.sh.
ENGINE=macos/Engine
if [ ! -x "$ENGINE/tsukiko-recognizer" ] || [ ! -x "$ENGINE/tsukiko-dictation" ]; then
  echo "Нет движка в $ENGINE. Соберите: ./tool/engine.sh" >&2
  exit 1
fi
# Helpers — место для вложенных программ, и по правилам подписи там
# не должно лежать ничего, кроме них: лицензия едет в Resources.
mkdir -p "$APP/Contents/Helpers"
cp "$ENGINE/tsukiko-recognizer" "$ENGINE/tsukiko-dictation" "$APP/Contents/Helpers/"
cp "$ENGINE/whisper.cpp-LICENSE.txt" "$APP/Contents/Resources/"

# Вложенное подписывается первым: подпись бандла запечатывает то, что внутри.
find "$APP/Contents/Frameworks" "$APP/Contents/Helpers" -depth 1 -print0 |
  xargs -0 -I{} codesign --force --sign "$ID" --timestamp=none {}
codesign --force --sign "$ID" --timestamp=none \
  --entitlements macos/Runner/Release.entitlements "$APP"
codesign -dv "$APP" 2>&1 | grep -E 'Authority|TeamIdentifier' || true
