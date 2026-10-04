"""Настройки dmgbuild; геометрия общая с генератором фона."""

import os
import sys
from pathlib import Path

# dmg.sh запускает dmgbuild из корня проекта; настройки исполняются без __file__.
ROOT = Path.cwd()
sys.path.insert(0, str(ROOT / "tool"))
from dmg_layout import ICON_SIZE, ICON_Y, LEFT_X, RIGHT_X, WINDOW_SIZE

format = "UDZO"
compression_level = 9
filesystem = "HFS+"
files = [(os.environ["TSUKIKO_DMG_APP"], "tsukiko.app")]
symlinks = {"Applications": "/Applications"}
background = str(ROOT / "design" / "dmg-background.tiff")
window_rect = ((200, 140), WINDOW_SIZE)
icon_locations = {"tsukiko.app": (LEFT_X, ICON_Y), "Applications": (RIGHT_X, ICON_Y)}
icon_size = ICON_SIZE
text_size = 12
default_view = "icon-view"
arrange_by = None
show_toolbar = False
show_sidebar = False
show_status_bar = False
show_pathbar = False
show_tab_view = False
include_icon_view_settings = True
include_list_view_settings = False
