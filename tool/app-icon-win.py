#!/usr/bin/env python3
"""Собрать значок приложения для Windows из того же рисунка, что и на macOS.

Зачем скриптом, а не руками: значок в `windows/runner/resources/app_icon.ico`
достался от заготовки Flutter — там до сих пор лежал синий логотип самого
Flutter. Заметить это трудно: он выглядит как значок приложения, просто
чужого. Пусть собирается из `design/tsukiko-appicon.svg`, как и все
остальные наши картинки, — тогда правка рисунка доедет до всех мест разом.

Углы у macOS свои, скруглённые по её правилам; Windows квадратных углов
не навязывает и рисует значок как есть, поэтому берём тот же файл без
переделки — форма скругления в самом рисунке.

Запуск: python3 tool/app-icon-win.py (нужен rsvg-convert и Pillow)
"""

import io
import subprocess
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / "design" / "tsukiko-appicon.svg"
OUT = ROOT / "windows" / "runner" / "resources" / "app_icon.ico"

# Те размеры, которые Windows правда просит: 16 и 20 — список и панель
# задач, 32 — рабочий стол, 48 — крупные значки, 64 и 256 — «плитки»
# и предпросмотр. Меньше 16 система масштабирует сама и делает это плохо,
# больше 256 в .ico не кладут.
SIZES = [16, 20, 24, 32, 40, 48, 64, 128, 256]


def render(size: int) -> Image.Image:
    png = subprocess.run(
        ["rsvg-convert", "-w", str(size), "-h", str(size), str(SRC)],
        capture_output=True, check=True).stdout
    return Image.open(io.BytesIO(png)).convert("RGBA")


def main() -> int:
    if not SRC.exists():
        print(f"нет рисунка: {SRC}", file=sys.stderr)
        return 1
    # Каждый размер рисуется из вектора отдельно, а не уменьшением одного
    # большого: мелкие значки от уменьшения мылятся, а 16 точек — это
    # то, что человек видит в панели задач чаще всего.
    frames = [render(s) for s in SIZES]
    frames[-1].save(OUT, format="ICO", sizes=[(s, s) for s in SIZES])
    print(f"собран: {OUT.relative_to(ROOT)} ({OUT.stat().st_size // 1024} КБ, "
          f"размеров {len(SIZES)})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
