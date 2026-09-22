#!/usr/bin/env bash
set -e

# Tsukiko Icon Composer Export Script
# Uses Apple's ictool bundled with Xcode / Icon Composer 27

DIR="$(cd "$(dirname "$0")/.." && pwd)"
ICTOOL="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
RENDERS="$DIR/renders"

if [ ! -f "$ICTOOL" ]; then
  echo "Error: ictool not found at $ICTOOL"
  exit 1
fi

mkdir -p "$RENDERS"

echo "=== Exporting macOS Icons ==="
"$ICTOOL" "$DIR/Tsukiko.icon" --export-image --output-file "$RENDERS/macos_default_1024.png" --platform macOS --rendition Default --width 1024 --height 1024 --scale 1 --design-generation 27
"$ICTOOL" "$DIR/Tsukiko.icon" --export-image --output-file "$RENDERS/macos_dark_1024.png" --platform macOS --rendition Dark --width 1024 --height 1024 --scale 1 --design-generation 27
"$ICTOOL" "$DIR/Tsukiko.icon" --export-image --output-file "$RENDERS/macos_mono_1024.png" --platform macOS --rendition Mono --width 1024 --height 1024 --scale 1 --design-generation 27
"$ICTOOL" "$DIR/Tsukiko.icon" --export-image --output-file "$RENDERS/macos_tinted_dark_1024.png" --platform macOS --rendition TintedDark --width 1024 --height 1024 --scale 1 --tint-color 0.298 --tint-strength 0.75 --design-generation 27

echo "=== Exporting iOS Adaptive Icons ==="
"$ICTOOL" "$DIR/Tsukiko-AdaptiveFill.icon" --export-image --output-file "$RENDERS/ios_default_1024.png" --platform iOS --rendition Default --width 1024 --height 1024 --scale 1 --design-generation 27
"$ICTOOL" "$DIR/Tsukiko-AdaptiveFill.icon" --export-image --output-file "$RENDERS/ios_dark_1024.png" --platform iOS --rendition Dark --width 1024 --height 1024 --scale 1 --design-generation 27
"$ICTOOL" "$DIR/Tsukiko-AdaptiveFill.icon" --export-image --output-file "$RENDERS/ios_tinted_1024.png" --platform iOS --rendition TintedDark --width 1024 --height 1024 --scale 1 --tint-color 0.298 --tint-strength 0.75 --design-generation 27

echo "=== Exporting watchOS Circular Icons ==="
"$ICTOOL" "$DIR/Tsukiko-AdaptiveFill.icon" --export-image --output-file "$RENDERS/watchos_default_1024.png" --platform watchOS --rendition Default --width 1024 --height 1024 --scale 1 --design-generation 27
"$ICTOOL" "$DIR/Tsukiko-AdaptiveFill.icon" --export-image --output-file "$RENDERS/watchos_dark_1024.png" --platform watchOS --rendition Dark --width 1024 --height 1024 --scale 1 --design-generation 27

echo "All icons successfully exported to: $RENDERS"
