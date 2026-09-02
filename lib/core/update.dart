import 'dart:convert';
import 'dart:io';

import '../platform/os.dart';

/// Проверка обновлений.
///
/// Своего механизма самообновления нет намеренно. Он потребовал бы
/// подписанного канала и родной зависимости на каждой системе — Sparkle
/// на macOS, WinSparkle на Windows, — то есть кода, который сам скачивает
/// и сам подменяет исполняемый файл. Такому коду нужно доверять больше,
/// чем всему остальному приложению вместе взятому, а выигрыш — два
/// щелчка.
///
/// Поэтому: приложение только спрашивает, есть ли версия новее, и,
/// если есть, отводит человека на страницу выпуска. Скачивает и ставит
/// он сам — dmg на macOS, установщик на Windows. Ставится обновление
/// поверх, настройки и модели лежат отдельно и переезд переживают.
class Update {
  const Update(this.version, this.url, this.notes);

  final String version;
  final String url;
  final String notes;
}

/// Где лежит опись выпусков. Один файл на обе системы: страница выпуска
/// у них общая, а какой файл качать — видно на ней.
const releasesUrl =
    'https://api.github.com/repos/Yukovsky/tsukiko/releases/latest';

/// Есть ли версия новее [current]. Нет сети, нет ответа, чужой ответ —
/// значит новостей нет: проверка обновлений не тот повод, чтобы
/// беспокоить человека сообщением об ошибке.
Future<Update?> checkForUpdate(String current, {String url = releasesUrl}) async {
  try {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    final request = await client.getUrl(Uri.parse(url));
    request.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
    final response = await request.close();
    if (response.statusCode != 200) return null;
    final body = jsonDecode(await response.transform(utf8.decoder).join());
    client.close();

    final tag = ((body as Map)['tag_name'] as String?)?.trim();
    if (tag == null || tag.isEmpty) return null;
    final latest = tag.startsWith('v') ? tag.substring(1) : tag;
    if (!isNewer(latest, current)) return null;
    return Update(
      latest,
      (body['html_url'] as String?) ?? 'https://github.com/Yukovsky/tsukiko/releases',
      (body['body'] as String?)?.trim() ?? '',
    );
  } catch (_) {
    return null;
  }
}

/// Сравнение версий по числам, а не по строкам: «1.10.0» новее «1.9.0»,
/// хотя как строка она меньше.
bool isNewer(String candidate, String current) {
  List<int> parts(String v) => [
        for (final p in v.split(RegExp(r'[.+-]')))
          int.tryParse(p) ?? 0,
      ];
  final a = parts(candidate), b = parts(current);
  for (var i = 0; i < (a.length > b.length ? a.length : b.length); i++) {
    final x = i < a.length ? a[i] : 0;
    final y = i < b.length ? b[i] : 0;
    if (x != y) return x > y;
  }
  return false;
}

/// Открыть страницу выпуска в браузере.
Future<void> openReleasePage(String url) => os.openUrl(url);
