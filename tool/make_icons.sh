#!/bin/sh
# Пересобирает растр иконок из design/*.svg. Запускать после правки SVG.
# Нужен rsvg-convert (brew install librsvg).
set -e
cd "$(dirname "$0")/.."

app=macos/Runner/Assets.xcassets/AppIcon.appiconset
bar=macos/Runner/Assets.xcassets/MenuBarIcon.imageset

for s in 32 64 128 256 512 1024; do
  rsvg-convert -w $s -h $s design/tsukiko-appicon.svg -o $app/app_icon_$s.png
done
# на 16 точках силуэт упрощён — почему, написано в самом файле
rsvg-convert -w 16 -h 16 design/tsukiko-appicon-16.svg -o $app/app_icon_16.png

rsvg-convert -w 18 -h 18 design/tsukiko-menubar.svg -o $bar/menubar.png
rsvg-convert -w 36 -h 36 design/tsukiko-menubar.svg -o $bar/menubar@2x.png

echo "готово"
