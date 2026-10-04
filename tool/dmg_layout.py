"""Координаты фона и значков в области содержимого окна Finder (точки)."""

WINDOW_SIZE = (640, 440)
# Finder может показывать системную строку пути независимо от настроек образа.
# Учитываем заголовок и нижние строки, чтобы декор не попадал под них.
CONTENT_HEIGHT = WINDOW_SIZE[1] - 64
ICON_SIZE = 96
ICON_Y = 180
LEFT_X, RIGHT_X = 160, 480
CARD_SIZE = 160
CARD_TOP = 116
CORNER_INSET = 24
MASCOT_HEIGHT = 72
