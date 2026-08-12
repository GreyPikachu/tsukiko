part of 'main.dart';

/// Модальные окна: сообщение, вопрос «продолжить?» и «О программе».
extension _Dialogs on _HomePageState {
  // ── диалоги ───────────────────────────────────────────────────────────────

  void _alert(String title, String message) => showMacosAlertDialog<void>(
        context: context,
        builder: (dialogContext) => MacosAlertDialog(
          appIcon: const MacosIcon(CupertinoIcons.waveform, size: 56),
          title: Text(title, style: Type.emptyTitle),
          message: Text(message, textAlign: TextAlign.center, style: Type.control),
          primaryButton: PushButton(
            controlSize: ControlSize.large,
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Понятно'),
          ),
        ),
      );

  Future<bool> _confirm(String title, String message) async {
    var result = false;
    await showMacosAlertDialog<void>(
      context: context,
      builder: (dialogContext) => MacosAlertDialog(
        appIcon: const MacosIcon(CupertinoIcons.waveform_circle, size: 56),
        title: Text(title, style: Type.emptyTitle),
        message: Text(message, textAlign: TextAlign.center, style: Type.control),
        primaryButton: PushButton(
          controlSize: ControlSize.large,
          onPressed: () {
            result = true;
            Navigator.pop(dialogContext);
          },
          child: const Text('Продолжить'),
        ),
        secondaryButton: PushButton(
          controlSize: ControlSize.large,
          secondary: true,
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Отмена'),
        ),
      ),
    );
    return result;
  }

  void _about() => showMacosAlertDialog<void>(
        context: context,
        builder: (dialogContext) => MacosAlertDialog(
          appIcon: const MacosIcon(CupertinoIcons.waveform_circle_fill, size: 56),
          title: const Text(appName, style: Type.emptyTitle),
          message: Text(
            'Распознавание речи на самом компьютере.\n'
            'Движок: whisper.cpp · ничего не уходит в сеть.',
            textAlign: TextAlign.center,
            style: Type.control,
          ),
          primaryButton: PushButton(
            controlSize: ControlSize.large,
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Закрыть'),
          ),
        ),
      );
}
