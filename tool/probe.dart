// Ручная проверка детектора занятости: запусти рядом любое распознавание
// (whisper-cli, чужой распознаватель) и смотри, ловит ли его tsukiko.
//   dart run tool/probe.dart
// ignore_for_file: avoid_print
import 'package:tsukiko/engine.dart';

Future<void> main() async {
  final models = findModels();
  if (models.isEmpty) {
    print('Моделей не найдено — проверять нечего.');
    return;
  }
  print('Слежу за ${models.length} ${plural(models.length, 'моделью', 'моделями', 'моделями')}:');
  for (final m in models) {
    print('  ${m.split('/').last}');
  }
  print('');

  var learned = <String>{};
  var cpu = const CpuSample.empty();
  for (var i = 0; i < 90; i++) {
    final use = await modelUsage(
      modelPath: models.first,
      others: models,
      learned: learned,
      previous: cpu,
      probeHolders: i % 3 == 0,
    );
    learned = use.learned;
    cpu = use.cpu;
    final mark = use.busy ? '●' : '·';
    print('${(i * 0.7).toStringAsFixed(1).padLeft(5)}s $mark '
        '${use.label.padRight(34)} ядер: ${use.share.toStringAsFixed(2).padLeft(5)}'
        '  память: ${(use.rssKb / 1024).round().toString().padLeft(5)} МБ'
        '  выучено: $learned');
    await Future<void>.delayed(const Duration(milliseconds: 700));
  }
}
