# Tsukiko — Apple Icon Composer Pack

Комплект адаптивных иконкок приложения Tsukiko для **Apple Icon Composer** (Xcode 27+, macOS 26/27, iOS 18+, watchOS), поддерживающий физический рендеринг **Liquid Glass**, разделение на слои, преломление света, глубину и все системные оформления (Default, Dark, Monochrome, Tinted).

---

## 📁 Структура директории

```
/Users/yuko/tsukiko/icon/
├── Tsukiko.icon/                 # Пакет Icon Composer (macOS суперэллипс + маскот)
│   ├── icon.json                 # Конфигурация слоёв, групп, Liquid Glass и градиентов
│   └── Assets/
│       ├── cat_eyes.svg          # Слой глаз котика (верхний слой)
│       └── cat_body.svg          # Слой силуэта котика (с эффектом glass)
│
├── Tsukiko-AdaptiveFill.icon/    # Пакет Icon Composer с адаптивным системным фоном (iOS/watchOS/macOS)
│   ├── icon.json
│   └── Assets/
│       ├── cat_eyes.svg
│       └── cat_body.svg
│
├── layers/                       # Исходные независимые слои
│   ├── png/                      # Растровые слои 1024×1024 с прозрачным фоном
│   │   ├── 00_full_icon_1024.png
│   │   ├── 01_plate_clean_1024.png
│   │   ├── 01_plate_with_shadow_1024.png
│   │   ├── 02_cat_body_1024.png
│   │   ├── 03_cat_eyes_1024.png
│   │   └── 04_cat_composite_1024.png
│   └── svg/                      # Векторные слои (SVG)
│       ├── 00_full_icon.svg
│       ├── 01_plate_clean.svg
│       ├── 01_plate_with_shadow.svg
│       ├── 02_cat_body.svg
│       ├── 03_cat_eyes.svg
│       └── 04_cat_composite.svg
│
├── renders/                      # Сгенерированные готовые растры через ictool (1024×1024)
│   ├── macos_default_1024.png    # macOS стандартный вид
│   ├── macos_dark_1024.png       # macOS тёмная тема
│   ├── macos_mono_1024.png       # macOS монохромный режим
│   ├── macos_tinted_dark_1024.png# macOS акцентный тинт
│   ├── ios_default_1024.png      # iOS скругленный квадрат
│   ├── ios_dark_1024.png         # iOS тёмная тема
│   ├── ios_tinted_1024.png       # iOS тинт
│   ├── watchos_default_1024.png  # watchOS круглый формат
│   └── watchos_dark_1024.png     # watchOS тёмный
│
└── scripts/
    └── export_icons.sh           # Скрипт пересборки всех рендеров через ictool
```

---

## 🔮 Как работает Liquid Glass в `icon.json`

В пакетах `.icon` эффект **Liquid Glass** настраивается через параметры группы и слоя:

```json
{
  "fill": {
    "linear-gradient": [
      "extended-srgb:0.29804,0.31765,0.60000,1.00000",
      "extended-srgb:0.17255,0.18431,0.38824,1.00000"
    ]
  },
  "groups": [
    {
      "name": "Mascot Liquid Glass",
      "layers": [
        {
          "name": "Eyes",
          "image-name": "cat_eyes.svg"
        },
        {
          "name": "Fur Silhouette",
          "image-name": "cat_body.svg",
          "glass": true
        }
      ],
      "blur-material": 0.5,
      "refractivity": true,
      "refractivity-depth": 0.05,
      "refractivity-strength": 0.5,
      "shadow": {
        "kind": "neutral",
        "opacity": 0.5
      },
      "specular": "automatic",
      "translucency": {
        "enabled": true,
        "value": 0.35
      }
    }
  ],
  "supported-platforms": {
    "circles": ["watchOS"],
    "squares": "shared"
  }
}
```

- **`glass: true`**: активирует поведение стекла для контура маскота.
- **`refractivity` + `refractivity-strength` + `depth`**: включает преломление света сквозь фигуру кота (видны искажения градиента фона).
- **`translucency`**: настраивает прозрачность и светопроницаемость стекла.
- **`specular: "automatic"`**: генерирует реалистичный световой блик по контуру.
- **`blur-material: 0.5`**: матовое размытие фона внутри стеклянного тела.

---

## 🖥 Как открыть и редактировать в GUI

Вы можете открыть любой из пакетов двойным кликом в Finder или через терминал:

```bash
open -a "Icon Composer" /Users/yuko/tsukiko/icon/Tsukiko.icon
```

В интерфейсе Icon Composer доступны интерактивные ползунки:
- Переключение поколений дизайна (**Design Generation 27** для Liquid Glass).
- Настройка силы преломления (**Refraction**, **Specular**, **Blur**, **Translucency**, **Shadow**).
- Превью в реальном времени под macOS, iOS и watchOS в режимах **Default**, **Dark**, **Mono**, **Tinted**.

---

## ⚙️ Пересборка растров из терминала

Запустите скрипт для обновления всех картинок в папке `renders/`:

```bash
/Users/yuko/tsukiko/icon/scripts/export_icons.sh
```

Либо вызовите утилиту напрямую:
```bash
/Applications/Xcode.app/Contents/Applications/Icon\ Composer.app/Contents/Executables/ictool \
  /Users/yuko/tsukiko/icon/Tsukiko.icon \
  --export-image \
  --output-file /tmp/icon.png \
  --platform macOS \
  --rendition Default \
  --width 1024 --height 1024 --scale 2 \
  --design-generation 27
```
