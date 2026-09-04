#!/usr/bin/env python3
"""Нарисовать картинки для окна установщика Inno Setup.

Зачем вообще: без них мастер выглядит как всякий второй установщик
из девяностых — серая полоса слева и ни одного признака того, что
именно ставится. На macOS ту же работу делает окно образа
(`tool/dmg.sh`): открыл — и сразу видно, что за программа и что с ней
делать. Здесь то же самое, только средствами Inno Setup: большая
картинка на первой и последней странице и маленькая — в шапке
остальных.

Рисуется тем же, чем фон образа на macOS: SVG → rsvg-convert → Pillow.
Нужны они ровно один раз — готовые BMP лежат в design/ и в репозитории.

Запуск: python3 tool/installer-images.py (нужен rsvg-convert и Pillow)
"""

import io
import subprocess
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
DESIGN = ROOT / "design"
ICON = DESIGN / "tsukiko-appicon.svg"
MASCOT = ROOT / "assets" / "mascot" / "happy.webp"

# Размеры задаёт Inno Setup: большая картинка 164×314, маленькая 55×58.
# Каждой рисуем ещё и удвоенную — на экране с двойной плотностью Inno
# берёт её сам, а растянутая единичная выглядела бы мылом.
BANNER = (164, 314)
LOGO = (55, 58)

# Тот же сине-сиреневый, что у значка и у маскота.
BANNER_SVG = """<svg xmlns="http://www.w3.org/2000/svg" width="164" height="314">
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="0.4" y2="1">
      <stop offset="0" stop-color="#8B8FCB"/>
      <stop offset="1" stop-color="#4A4D77"/>
    </linearGradient>
    <radialGradient id="glow" cx="0.5" cy="0.3" r="0.7">
      <stop offset="0" stop-color="#ffffff" stop-opacity="0.20"/>
      <stop offset="1" stop-color="#ffffff" stop-opacity="0"/>
    </radialGradient>
  </defs>
  <rect width="164" height="314" fill="url(#bg)"/>
  <rect width="164" height="314" fill="url(#glow)"/>
  <text x="82" y="42" text-anchor="middle"
        font-family="Segoe UI, Helvetica, sans-serif"
        font-size="22" font-weight="600" fill="#ffffff" letter-spacing="0.5">tsukiko</text>
  <text x="82" y="64" text-anchor="middle"
        font-family="Segoe UI, Helvetica, sans-serif"
        font-size="10" fill="#ffffff" fill-opacity="0.72">расшифровка и диктовка</text>
</svg>
"""


def render(svg: str, size: tuple[int, int], scale: int) -> Image.Image:
    png = subprocess.run(
        ["rsvg-convert", "-w", str(size[0] * scale), "-h", str(size[1] * scale)],
        input=svg.encode(), capture_output=True, check=True).stdout
    return Image.open(io.BytesIO(png)).convert("RGBA")


def banner(scale: int) -> Image.Image:
    canvas = render(BANNER_SVG, BANNER, scale)
    # Кот лежит на нижнем краю полосы — так он и нарисован: кадр
    # маскота обрезан снизу нарочно, кот в нём лежит, а не парит.
    # Прозрачные поля кадра сначала срезаем, иначе он встал бы боком.
    cat = Image.open(MASCOT).convert("RGBA")
    cat = cat.crop(cat.getbbox())
    width = int(BANNER[0] * scale)
    height = int(cat.height * width / cat.width)
    cat = cat.resize((width, height), Image.LANCZOS)
    canvas.alpha_composite(cat, (0, BANNER[1] * scale - height))
    return canvas.convert("RGB")


def logo(scale: int) -> Image.Image:
    # Значок приложения на белом: шапка мастера белая, и прозрачность
    # BMP не хранит вовсе — подложку надо положить самим.
    icon = render(ICON.read_text(encoding="utf-8"), (LOGO[1], LOGO[1]), scale)
    canvas = Image.new("RGBA", (LOGO[0] * scale, LOGO[1] * scale), (255, 255, 255, 255))
    canvas.alpha_composite(icon, ((canvas.width - icon.width) // 2, 0))
    return canvas.convert("RGB")


def main() -> int:
    made = []
    for name, draw in (("installer-banner", banner), ("installer-logo", logo)):
        for scale, suffix in ((1, ""), (2, "@2x")):
            out = DESIGN / f"{name}{suffix}.bmp"
            # 24 бита без сжатия: другого Inno Setup не читает.
            draw(scale).save(out, format="BMP")
            made.append(out)
    for out in made:
        print(f"нарисовано: {out.relative_to(ROOT)} ({out.stat().st_size // 1024} КБ)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
