import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../library.dart' show supportDir, writeJsonAtomically;
import '../../platform/os.dart' show os;

/// Профиль голоса пользователя (Voiceprint Enrollment).
///
/// Содержит эмбеддинги 3-5 контрольных записей ключевых слов, извлечённых
/// с помощью `SpeakerEmbeddingExtractor`. При появлении ключевого слова в аудиопотоке
/// его эмбеддинг сверяется с этим профилем, предотвращая ложные срабатывания от посторонних.
class SpeakerProfile {
  const SpeakerProfile({
    required this.name,
    required this.dimension,
    required this.embeddings,
    this.createdAt,
  });

  final String name;
  final int dimension;
  final List<Float32List> embeddings;
  final DateTime? createdAt;

  static String get defaultPath => os.join(supportDir, 'speaker_profile.json');
  static String get defaultProfilePath => defaultPath;

  /// Проверить наличие сохранённого профиля на диске.
  static bool exists([String? path]) {
    return load(path) != null;
  }

  /// Удалить сохранённый профиль.
  static bool delete([String? path]) {
    try {
      final file = File(path ?? defaultPath);
      if (file.existsSync()) {
        file.deleteSync();
        return true;
      }
    } catch (_) {}
    return false;
  }

  /// Загрузить профиль с диска.
  static SpeakerProfile? load([String? path]) {
    try {
      final file = File(path ?? defaultPath);
      if (!file.existsSync() || file.lengthSync() == 0) return null;
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final profile = SpeakerProfile.fromJson(json);
      if (profile.embeddings.isEmpty) return null;
      return profile;
    } catch (_) {
      return null;
    }
  }

  /// Сохранить профиль атомарно.
  void save([String? path]) {
    try {
      final file = File(path ?? defaultPath);
      file.parent.createSync(recursive: true);
      writeJsonAtomically(file, toJson());
    } catch (e) {
      stderr.writeln('tsukiko: не удалось сохранить профиль голоса — $e');
    }
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'dimension': dimension,
        'createdAt': (createdAt ?? DateTime.now()).toIso8601String(),
        'embeddings': [
          for (final emb in embeddings)
            [for (var i = 0; i < emb.length; i++) emb[i]],
        ],
      };

  factory SpeakerProfile.fromJson(Map<String, dynamic> json) {
    final dim = (json['dimension'] as num?)?.toInt() ?? 0;
    final rawEmbeddings = (json['embeddings'] as List? ?? const []);
    final embeddingsList = <Float32List>[];

    for (final raw in rawEmbeddings) {
      if (raw is List) {
        if (dim > 0 && raw.length != dim) continue;
        final f = Float32List(raw.length);
        var valid = true;
        for (var i = 0; i < raw.length; i++) {
          final v = raw[i];
          if (v is! num) {
            valid = false;
            break;
          }
          f[i] = v.toDouble();
        }
        if (valid) {
          embeddingsList.add(f);
        }
      }
    }

    return SpeakerProfile(
      name: (json['name'] as String?) ?? 'user',
      dimension: dim > 0 ? dim : (embeddingsList.isNotEmpty ? embeddingsList.first.length : 0),
      embeddings: embeddingsList,
      createdAt: json['createdAt'] != null
          ? DateTime.tryParse(json['createdAt'] as String)
          : null,
    );
  }

  /// Косинусное сходство между двумя векторами эмбеддингов: dot(a, b) / (|a| * |b|).
  ///
  /// Диапазон от -1.0 до 1.0. Для одинакового голоса обычно > 0.60..0.75.
  static double cosineSimilarity(Float32List a, Float32List b) {
    if (a.length != b.length || a.isEmpty) return 0.0;
    double dot = 0.0;
    double normA = 0.0;
    double normB = 0.0;

    for (var i = 0; i < a.length; i++) {
      final x = a[i];
      final y = b[i];
      dot += x * y;
      normA += x * x;
      normB += y * y;
    }

    if (normA <= 0.0 || normB <= 0.0 || normA.isNaN || normB.isNaN) return 0.0;
    final sim = dot / (math.sqrt(normA) * math.sqrt(normB));
    return sim.isNaN ? 0.0 : sim;
  }

  /// Вычислить максимальное и среднее сходство кандидата с зарегистрированными эмбеддингами.
  double similarity(Float32List candidate) {
    if (embeddings.isEmpty || candidate.length != dimension) return 0.0;
    double maxScore = -1.0;
    double sum = 0.0;

    for (final ref in embeddings) {
      final score = cosineSimilarity(ref, candidate);
      if (score > maxScore) maxScore = score;
      sum += score;
    }

    // Взвешенное среднее между максимумом и средним (70% max, 30% avg)
    final avg = sum / embeddings.length;
    return (0.7 * maxScore) + (0.3 * avg);
  }

  /// Верифицировать, принадлежит ли кандидат владельцу профиля.
  bool verify(Float32List candidate, double threshold) {
    if (embeddings.isEmpty) return true; // Без калибровки не блокируем
    return similarity(candidate) >= threshold;
  }
}
