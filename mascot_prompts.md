# Промпты для маскота tsukiko

К каждому промпту прикладывайте `mascot_reference_cutout.png` — вырезанного персонажа на прозрачном фоне. Так генератор поймёт, какой именно кот нужен.

---

## Как этим пользоваться

1. Сначала сгенерируйте **состояние 1 (покой)** — это эталон.
2. Выберите лучший результат и дальше прикладывайте **его** как референс к остальным состояниям (вместе с исходной вырезкой). Это единственный надёжный способ удержать одного и того же персонажа во всех кадрах.
3. Все шесть картинок должны быть **одного размера, с котом в одном и том же месте кадра и одного масштаба** — иначе при переключении состояний он будет прыгать.

---

## Технические требования (добавлять в конец каждого промпта)

```
TECHNICAL REQUIREMENTS:
- PNG with real alpha transparency. Transparent background, NOT white, NOT a checkerboard pattern.
- 1024x1024 square canvas. Character centered, occupying ~80% of frame height, 10% margin on all sides.
- Flat vector illustration. Solid fills only.
- NO gradients inside the body, NO shading, NO ambient occlusion, NO drop shadow, NO glow, NO outline stroke, NO texture, NO grain, NO paper effect.
- Clean smooth vector curves with rounded joints. No jagged or wobbly edges.
- Perfectly symmetrical front-facing pose unless the prompt says otherwise.
- Single character only. No background elements, no stars, no scenery, no text, no watermark, no signature.

EXACT COLORS:
- Body silhouette: #8A90CC (soft periwinkle blue-lavender)
- Eyes: #FFFFFF (pure white)
- Inner detail lines (paws, chin separation): #4E5390
- Blush: #E88AA8
```

---

## Общее описание персонажа (базовый блок)

Вставляйте этот блок в каждый промпт — он держит персонажа одинаковым.

```
CHARACTER: A small chibi cat mascot called "the moon cat", drawn as a flat vector
silhouette in soft periwinkle blue (#8A90CC).

HEAD: wide and low, wider than it is tall. Two large sharp triangular ears rising
from the top corners, tilted slightly outward, with a deep narrow V-shaped notch
between them. The lower sides of the head flare outward into two sharp horizontal
cheek points, like small wings, at eye level. Below the cheeks the head narrows into
a smooth rounded chin.

EYES: two very large pure white rounded shapes sitting low on the face, spaced wide
apart, tilted slightly. No pupils, no irises, no outline — just solid white shapes.

MOUTH: a tiny delicate curve centered between and slightly below the eyes.

BODY: a separate rounded shape below the head, narrow at the shoulders and widening
toward the bottom. A thin transparent gap separates head from body — they are two
distinct shapes, not merged.

LIMBS: two front paws folded and crossed in front of the body, drawn as slim curved
darker lines (#4E5390), not as filled shapes. A long slender tail curving down.

OVERALL: elongated vertical proportions, roughly 1 : 1.55 (width to height).
Cute, calm, minimal, soft. Think flat sticker art.
```

---

## Состояние 1 — Покой (idle)

Базовое состояние. Кот сидит на пустом экране и ждёт файлы.

```
[CHARACTER BLOCK]

POSE AND EXPRESSION: Sitting calmly, facing forward, perfectly symmetrical.
Eyes wide open, large and white, relaxed. Tiny neutral mouth curve.
Ears upright and alert. Tail resting, curving softly down and to one side.
Front paws folded and crossed in front of the chest.
Mood: serene, patient, waiting quietly.

[TECHNICAL REQUIREMENTS]
```

---

## Состояние 2 — Моргание (blink)

Нужен только для оживления покоя — глаза закрываются на пару кадров раз в несколько секунд. **Всё остальное в кадре должно быть в точности как в состоянии 1**, меняются только глаза.

```
[CHARACTER BLOCK]

IDENTICAL to the previous idle image in every way — same pose, same position,
same scale, same tail, same paws. The ONLY difference: the eyes are closed.

EYES CLOSED: instead of the white oval shapes, draw two smooth downward-curving
arcs in white (#FFFFFF), stroke width about 5% of head width, with rounded caps,
placed exactly where the open eyes were.

[TECHNICAL REQUIREMENTS]
```

---

## Состояние 3 — Слушает (идёт запись / распознавание)

Приложение обрабатывает аудио. Кот прислушивается.

```
[CHARACTER BLOCK]

POSE AND EXPRESSION: Alert and attentive, leaning forward very slightly.
Ears perked up higher and angled forward, clearly more raised than in the idle pose.
Eyes narrowed into attentive lens shapes — still solid white, but slimmer than the
idle eyes, as if concentrating on a sound. Small soft blush ovals (#E88AA8) on the
cheeks at low opacity. Tail lifted slightly, mid-flick.
Mood: focused, curious, listening intently to something.

[TECHNICAL REQUIREMENTS]
```

---

## Состояние 4 — Распознаёт (модель думает)

Долгая операция, кот сосредоточен.

```
[CHARACTER BLOCK]

POSE AND EXPRESSION: Sitting still, deeply concentrated, eyes gently closed.
EYES CLOSED: two smooth upward-curving arcs in white (#FFFFFF) with rounded caps,
suggesting peaceful concentration. Ears relaxed, tilted slightly back.
Head tipped a few degrees to one side, thoughtful.
Tiny closed mouth. Tail curled inward around the body, still.
Mood: patient, quietly working, absorbed in thought.

[TECHNICAL REQUIREMENTS]
```

---

## Состояние 5 — Клик по маскоту (радость)

Пользователь ткнул в кота — он радуется.

```
[CHARACTER BLOCK]

POSE AND EXPRESSION: Delighted and bouncy, body tilted about 5 degrees to one side
as if mid-hop. Happy squinting eyes: two upward-curving white arcs (#FFFFFF) shaped
like a joyful "^ ^", with rounded caps. Small open smiling mouth.
Warm blush ovals (#E88AA8) on both cheeks, more saturated than in other states.
Ears perked up cheerfully. Tail raised high and curved.
Front paws lifted slightly, as if reaching up in excitement.
Mood: pure delight, affectionate, happy to be noticed.

[TECHNICAL REQUIREMENTS]
```

---

## Состояние 6 — Файл над окном (drag & drop)

Пользователь тащит аудиофайл в окно — кот удивлён и тянется навстречу.

```
[CHARACTER BLOCK]

POSE AND EXPRESSION: Surprised and eager, looking upward. Eyes opened extra wide —
larger and rounder than the idle eyes, clearly startled with delight.
Ears standing straight up at full attention. Body stretched upward and leaning
slightly back, as if watching something descend toward it.
Front paws raised up and open, reaching to catch something.
Tail straight up with a small curl at the tip. Tiny open mouth.
Mood: excited anticipation, ready to catch.

[TECHNICAL REQUIREMENTS]
```

---

## Что я сделаю с готовыми картинками

1. Обведу каждую в чистый вектор (`Path` с кривыми Безье) — чистый арт трассируется идеально, в отличие от видеокадра.
2. Соберу `lib/mascot.dart`: один `CustomPainter`, переключение между состояниями на ваших `SpringCurve` из `design.dart`.
3. Свяжу с приложением: `_Placeholder` в центре экрана, `_running` и `job.active` для «слушает» и «распознаёт», `_DropVeil` для drag & drop, тап по коту — на радость.
4. Добавлю дыхание, случайное моргание и качание хвоста поверх статичных поз, с уважением к системной настройке «уменьшить движение».

Вектор нужен для того, чтобы кот подстраивался под светлую и тёмную тему, масштабировался без потери резкости и не утяжелял бандл.

---

## Если генератор не справится с прозрачностью

Ничего страшного — сгенерируйте на **сплошном ярко-зелёном фоне** (`#00FF00`), я сам вырежу. Главное, чтобы фон был однотонный и не совпадал с цветами персонажа.
