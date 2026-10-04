#!/usr/bin/env python3
"""Проверить подпись приложения и раскладку уже упакованного DMG."""

import hashlib
import plistlib
import subprocess
import sys
from pathlib import Path

from ds_store import DSStore
from dmg_layout import ICON_SIZE, ICON_Y, LEFT_X, RIGHT_X, WINDOW_SIZE


def verify(image: Path) -> None:
    result = subprocess.check_output([
        "hdiutil", "attach", "-readonly", "-nobrowse", "-noautoopen", "-plist", str(image)])
    entities = plistlib.loads(result)["system-entities"]
    device = entities[0]["dev-entry"]
    try:
        mount = Path(next(e["mount-point"] for e in entities if "mount-point" in e))
        subprocess.run(["codesign", "-v", "--deep", "--strict", str(mount / "tsukiko.app")], check=True)
        assert (mount / "Applications").readlink() == Path("/Applications"), "Ссылка Applications"
        background = mount / ".background.tiff"
        original = Path(__file__).resolve().parent.parent / "design" / "dmg-background.tiff"
        assert hashlib.sha256(background.read_bytes()).digest() == hashlib.sha256(original.read_bytes()).digest(), "Фон DMG устарел"
        with DSStore.open(str(mount / ".DS_Store"), "r") as store:
            assert store["tsukiko.app"]["Iloc"] == (LEFT_X, ICON_Y), "Положение приложения"
            assert store["Applications"]["Iloc"] == (RIGHT_X, ICON_Y), "Положение Applications"
            view = store["."]["icvp"]
            assert view["iconSize"] == ICON_SIZE, "Размер значков"
            assert view["textSize"] == 12 and view["labelOnBottom"], "Подписи значков"
            assert view["arrangeBy"] == "none", "Автоматическая сортировка значков включена"
            assert view["backgroundType"] == 2 and view["backgroundImageAlias"], "Фон не назначен"
            window = store["."]["bwsp"]
            assert window["WindowBounds"] == f"{{{{200, 140}}, {{{WINDOW_SIZE[0]}, {WINDOW_SIZE[1]}}}}}", "Размер окна"
            for flag in ("ShowToolbar", "ShowSidebar", "ShowStatusBar", "ShowPathbar", "ShowTabView"):
                assert not window[flag], f"Включено: {flag}"
        print(f"DMG проверен: {image.name} — подпись, фон, значки, подписи и окно")
    finally:
        subprocess.run(["hdiutil", "detach", device], check=True)


if __name__ == "__main__":
    verify(Path(sys.argv[1]).resolve())
