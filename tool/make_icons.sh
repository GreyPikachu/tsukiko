#!/bin/sh
# Пересобирает растр иконок из design/*.svg. Запускать после правки SVG.
# Нужен rsvg-convert (brew install librsvg).
set -e
cd "$(dirname "$0")/.."

app=macos/Runner/Assets.xcassets/AppIcon.appiconset
bar=macos/Runner/Assets.xcassets/MenuBarIcon.imageset

for s in 16 32 64 128 256 512 1024; do
  rsvg-convert -w $s -h $s design/tsukiko-appicon.svg -o $app/app_icon_$s.png
done

rsvg-convert -w 18 -h 18 design/tsukiko-menubar.svg -o $bar/menubar.png
rsvg-convert -w 36 -h 36 design/tsukiko-menubar.svg -o $bar/menubar@2x.png

echo "готово"
