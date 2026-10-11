import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../core/app_locale.dart';
import '../core/app_theme.dart';

/// Плавная смена темы: прежний кадр окна растворяется поверх нового.
///
/// Цвета по всему приложению выбираются по «тёмная или нет», и
/// интерполировать их нечем — поэтому перетекает картинка, а не тема.
/// Только Windows: на macOS то же самое делает сама система
/// (`DictationBridge.applyTheme`), заодно с рамкой и материалом окна.
class ThemeFade extends StatefulWidget {
  const ThemeFade({super.key, required this.child});

  final Widget child;

  @override
  State<ThemeFade> createState() => _ThemeFadeState();
}

class _ThemeFadeState extends State<ThemeFade>
    with SingleTickerProviderStateMixin {
  final _boundary = GlobalKey();
  late final AnimationController _fade;
  ui.Image? _old;

  @override
  void initState() {
    super.initState();
    _fade =
        AnimationController(
          vsync: this,
          duration: const Duration(milliseconds: 350),
        )..addStatusListener((status) {
          if (status == AnimationStatus.completed) _drop();
        });
    if (Platform.isWindows) appThemeMode.addListener(_capture);
  }

  /// Снимок берётся, пока на экране ещё старая тема: перестроится окно
  /// только к следующему кадру.
  void _capture() {
    final boundary = _boundary.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary || !mounted) return;
    try {
      final image = boundary.toImageSync(
        pixelRatio: View.of(context).devicePixelRatio,
      );
      _old?.dispose();
      setState(() => _old = image);
      _fade.forward(from: 0);
    } catch (_) {
      // Нечего снять (окно ещё не нарисовано) — сменится без перехода.
    }
  }

  void _drop() {
    if (_old == null) return;
    _old!.dispose();
    setState(() => _old = null);
  }

  @override
  void dispose() {
    appThemeMode.removeListener(_capture);
    _fade.dispose();
    _old?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    textDirection: TextDirection.ltr,
    fit: StackFit.passthrough,
    children: [
      RepaintBoundary(key: _boundary, child: widget.child),
      if (_old != null)
        Positioned.fill(
          child: IgnorePointer(
            child: FadeTransition(
              opacity: ReverseAnimation(
                CurvedAnimation(parent: _fade, curve: Curves.easeInOut),
              ),
              child: RawImage(image: _old, fit: BoxFit.fill),
            ),
          ),
        ),
    ],
  );
}

/// Корень окна: перестраивается по языку и теме и сменяет тему плавно.
class ThemedApp extends StatelessWidget {
  const ThemedApp({super.key, required this.builder});

  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) => ThemeFade(
    child: ListenableBuilder(
      listenable: Listenable.merge([appLocale, appThemeMode]),
      builder: (context, _) => builder(context),
    ),
  );
}
