#!/usr/bin/env python3
"""Нарисовать фон для окна .dmg — в двух разрешениях и одним TIFF.

Почему средний тон, а не светлый: Finder рисует подписи под значками
цветом темы — чёрным в светлой, белым в тёмной, — а картинка в образе
одна на обе. На светлом фоне белая подпись пропадает, на тёмном чёрная.
Взят тон, на котором читаются обе: контраст с чёрным 5,0, с белым 4,2.

Запуск: python3 tool/dmg-background.py (нужен rsvg-convert и Pillow)
Итог: design/dmg-background.tiff — его и кладёт в образ tool/dmg.sh
"""

import io
import subprocess
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "design" / "dmg-background.tiff"
MASCOT = ROOT / "assets" / "mascot" / "happy.webp"

# Размер окна образа в точках. Значки стоят в (150,190) и (450,190) —
# см. tool/dmg.sh, координаты обязаны совпадать.
W, H = 600, 400

SVG = f"""<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0.35" y2="1">
      <stop offset="0" stop-color="#8f8fa9"/>
      <stop offset="1" stop-color="#6d6d88"/>
    </linearGradient>
    <radialGradient id="glow" cx="0.5" cy="0.42" r="0.6">
      <stop offset="0" stop-color="#ffffff" stop-opacity="0.18"/>
      <stop offset="1" stop-color="#ffffff" stop-opacity="0"/>
    </radialGradient>
    <filter id="soft" x="-30%" y="-30%" width="160%" height="160%">
      <feGaussianBlur stdDeviation="10"/>
    </filter>
  </defs>

  <rect width="{W}" height="{H}" fill="url(#bg)"/>
  <rect width="{W}" height="{H}" fill="url(#glow)"/>

  <!-- Два места под значки: пунктирные гнёзда читаются как интерфейс,
       а не как украшение, — сразу видно, что и куда кладут. -->
  <rect x="94" y="134" width="112" height="112" rx="26"
        fill="#ffffff" fill-opacity="0.07"
        stroke="#ffffff" stroke-opacity="0.28" stroke-width="1.5"
        stroke-dasharray="7 6"/>
  <rect x="394" y="134" width="112" height="112" rx="26"
        fill="#ffffff" fill-opacity="0.10"
        stroke="#ffffff" stroke-opacity="0.34" stroke-width="1.5"/>

  <!-- Стрелка: единственное указание, и оно без слов — образ один
       на все языки. -->
  <g opacity="0.85" filter="url(#soft)">
    <path d="M232 190 H360" stroke="#ffffff" stroke-width="9"
          stroke-linecap="round" fill="none" opacity="0.35"/>
  </g>
  <path d="M232 190 H358" stroke="#ffffff" stroke-width="4"
        stroke-linecap="round" fill="none"/>
  <path d="M346 179 L364 190 L346 201" stroke="#ffffff" stroke-width="4"
        stroke-linecap="round" stroke-linejoin="round" fill="none"/>

  <text x="{W // 2}" y="72" text-anchor="middle"
        font-family="SF Pro Display, Helvetica Neue, Helvetica, sans-serif"
        font-size="28" font-weight="600" fill="#ffffff" fill-opacity="0.9"
        letter-spacing="0.5">tsukiko</text>
</svg>
"""


def render(scale: int) -> Image.Image:
    """SVG в растр нужного разрешения."""
    png = subprocess.run(
        ["rsvg-convert", "-w", str(W * scale), "-h", str(H * scale)],
        input=SVG.encode(), capture_output=True, check=True).stdout
    canvas = Image.open(io.BytesIO(png)).convert("RGBA")

    # Кот в нижнем углу — водяным знаком, а не героем: он даёт лицо,
    # но не спорит со значками, поверх которых человек работает.
    cat = Image.open(MASCOT).convert("RGBA")
    height = int(132 * scale)
    width = int(cat.width * height / cat.height)
    cat = cat.resize((width, height), Image.LANCZOS)
    faded = cat.copy()
    faded.putalpha(cat.getchannel("A").point(lambda a: int(a * 0.30)))
    # Целиком, а не срезанным краем: обрезанный кот читается пятном.
    # Не в самый низ: у многих включена строка пути, и она съедает
    # нижние тридцать точек окна.
    canvas.alpha_composite(faded, (int(18 * scale), (H - 168) * scale))
    return canvas.convert("RGB")


def main() -> int:
    OUT.parent.mkdir(parents=True, exist_ok=True)
    one, two = ROOT / "build" / "dmg-bg.png", ROOT / "build" / "dmg-bg@2x.png"
    one.parent.mkdir(parents=True, exist_ok=True)
    render(1).save(one)
    render(2).save(two)
    # Один файл на оба разрешения: Finder сам берёт нужное. Отдельного
    # «@2x» рядом он не ищет — только многостраничный TIFF.
    subprocess.run(
        ["tiffutil", "-cathidpicheck", str(one), str(two), "-out", str(OUT)],
        check=True, capture_output=True)
    one.unlink()
    two.unlink()
    print(f"нарисовано: {OUT.relative_to(ROOT)} ({OUT.stat().st_size // 1024} КБ)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
