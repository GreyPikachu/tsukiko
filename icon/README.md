# Tsukiko — Apple Icon Composer Pack

Adaptive icon assets for Tsukiko configured for **Apple Icon Composer** (Xcode, macOS, iOS, watchOS), supporting **Liquid Glass** physical rendering, layer separation, refraction, depth, and system appearance modes (Default, Dark, Monochrome, Tinted).

---

## Directory Structure

```
icon/
├── Tsukiko.icon/                 # macOS squircle icon package with mascot
│   ├── icon.json                 # Layer configuration, Liquid Glass materials, and gradients
│   └── Assets/
│       ├── cat_eyes.svg          # Top eye layer
│       └── cat_body.svg          # Mascot silhouette with glass shader
│
├── Tsukiko-AdaptiveFill.icon/    # Adaptive background variant (iOS/watchOS/macOS)
│   ├── icon.json
│   └── Assets/
│       ├── cat_eyes.svg
│       └── cat_body.svg
│
├── layers/                       # Independent source asset layers
│   ├── png/                      # 1024×1024 transparent raster layers
│   └── svg/                      # Scalable vector sources
│
├── renders/                      # Rendered 1024×1024 raster outputs
│   ├── macos_default_1024.png    # macOS default
│   ├── macos_dark_1024.png       # macOS dark mode
│   ├── macos_mono_1024.png       # macOS monochrome
│   └── macos_tinted_dark_1024.png# macOS tinted
│
└── scripts/
    └── export_icons.sh           # Batch raster export script using ictool
```

---

## Liquid Glass Configuration in `icon.json`

The `.icon` bundles configure physical **Liquid Glass** properties:

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

- **`glass: true`**: Applies glass physical shader to the mascot contour.
- **`refractivity` + `refractivity-strength` + `depth`**: Refracts underlying background gradients through the figure.
- **`translucency`**: Defines glass opacity and light transmission.
- **`specular: "automatic"`**: Produces edge highlights and specular reflections.
- **`blur-material: 0.5`**: Matte background blur through the glass volume.

---

## Editing via Icon Composer

Open either bundle in macOS Icon Composer:

```bash
open -a "Icon Composer" icon/Tsukiko.icon
```

---

## Exporting Rasters via CLI

Run the export script to update all images in `renders/`:

```bash
./icon/scripts/export_icons.sh
```

---

## Credits

Tsukiko mascot and character design based on artwork by [Feyza (feyzart.com)](https://feyzart.com/).
