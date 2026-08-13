#!/bin/sh
# Подписать собранное приложение постоянной подписью разработчика.
#
# Зачем: macOS привязывает выданные разрешения («Мониторинг ввода»,
# «Универсальный доступ») к подписи приложения. Flutter собирает с ad-hoc
# подписью, а её отпечаток меняется с каждой сборкой — выданное разрешение
# после пересборки перестаёт действовать, и диктовка молча замолкает.
# Подпись сертификатом из связки ключей одна и та же от сборки к сборке,
# поэтому разрешение выдаётся один раз.
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

# Вложенное подписывается первым: подпись бандла запечатывает то, что внутри.
find "$APP/Contents/Frameworks" -depth 1 -print0 |
  xargs -0 -I{} codesign --force --sign "$ID" --timestamp=none {}
codesign --force --sign "$ID" --timestamp=none \
  --entitlements macos/Runner/Release.entitlements "$APP"
codesign -dv "$APP" 2>&1 | grep -E 'Authority|TeamIdentifier' || true
