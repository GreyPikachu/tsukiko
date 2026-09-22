# Правила работы с tsukiko

Перед выпуском прочитайте [docs/версионирование.md](docs/версионирование.md).
Версия берётся из `pubspec.yaml`. Каждый официальный build для платформы
требует новой версии `MAJOR.MINOR.PATCH+BUILD`; CI отклоняет повторы. При
изменении версии обновите также `lib/platform/os.dart` и резервные значения
`windows/runner/Runner.rc`, затем выполните `python3 tool/version.py check`.
Не используйте маркеры `[build]`, `[build-windows]`, `[build-macos]` или
`[release]` в рабочем коммите, если сборка не нужна.
