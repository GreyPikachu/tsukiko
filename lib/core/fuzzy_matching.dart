import 'dart:math' as math;

/// High-performance Optimal String Alignment (OSA) Damerau-Levenshtein
/// metric with O(min(N, M)) memory footprint and bounded early-exit pruning.
class DamerauLevenshtein {
  const DamerauLevenshtein._();

  /// Calculates the Optimal String Alignment distance between [s1] and [s2].
  ///
  /// If [maxThreshold] is provided and the distance is mathematically
  /// guaranteed to exceed [maxThreshold], computation aborts early and returns
  /// [maxThreshold] + 1.
  static int distance(String s1, String s2, [int? maxThreshold]) {
    if (identical(s1, s2) || s1 == s2) return 0;
    if (s1.isEmpty) {
      if (maxThreshold != null && s2.length > maxThreshold) {
        return maxThreshold + 1;
      }
      return s2.length;
    }
    if (s2.isEmpty) {
      if (maxThreshold != null && s1.length > maxThreshold) {
        return maxThreshold + 1;
      }
      return s1.length;
    }

    // Fast length difference pruning
    final lenDiff = (s1.length - s2.length).abs();
    if (maxThreshold != null && lenDiff > maxThreshold) {
      return maxThreshold + 1;
    }

    // Ensure s2 is the shorter string to optimize memory to O(min(N, M))
    var a = s1;
    var b = s2;
    if (a.length < b.length) {
      a = s2;
      b = s1;
    }

    final n = a.length;
    final m = b.length;

    // Three rolling row buffers:
    // r0 = row (i - 2) for transposition lookback
    // r1 = row (i - 1)
    // r2 = row (i) current row being calculated
    var r0 = List<int>.filled(m + 1, 0);
    var r1 = List<int>.filled(m + 1, 0);
    var r2 = List<int>.filled(m + 1, 0);

    for (var j = 0; j <= m; j++) {
      r1[j] = j;
    }

    final codeUnitsA = a.codeUnits;
    final codeUnitsB = b.codeUnits;

    for (var i = 1; i <= n; i++) {
      r2[0] = i;
      final charA = codeUnitsA[i - 1];
      var minRowVal = r2[0];

      for (var j = 1; j <= m; j++) {
        final charB = codeUnitsB[j - 1];
        final cost = (charA == charB) ? 0 : 1;

        var dist = r1[j] + 1; // Deletion
        final insertion = r2[j - 1] + 1;
        if (insertion < dist) dist = insertion;

        final substitution = r1[j - 1] + cost;
        if (substitution < dist) dist = substitution;

        // Check transposition of adjacent characters
        if (i > 1 &&
            j > 1 &&
            charA == codeUnitsB[j - 2] &&
            codeUnitsA[i - 2] == charB) {
          final transposition = r0[j - 2] + 1;
          if (transposition < dist) dist = transposition;
        }

        r2[j] = dist;
        if (dist < minRowVal) minRowVal = dist;
      }

      // Early row exit for bounded search
      if (maxThreshold != null && minRowVal > maxThreshold) {
        return maxThreshold + 1;
      }

      // Rotate buffers: r0 <- r1, r1 <- r2, r2 <- r0
      final temp = r0;
      r0 = r1;
      r1 = r2;
      r2 = temp;
    }

    return r1[m];
  }

  /// Calculates the normalized similarity score S(A, B) in [0.0, 1.0].
  static double similarity(String s1, String s2) {
    if (s1 == s2) return 1.0;
    final maxLen = math.max(s1.length, s2.length);
    if (maxLen == 0) return 1.0;
    final d = distance(s1, s2);
    return math.max(0.0, 1.0 - (d / maxLen));
  }

  /// Evaluates the length-adaptive error threshold tau(L).
  ///
  /// Prevents false positive matches on short words (L <= 3) while allowing
  /// sublinear tolerance for longer expressions.
  static int adaptiveThreshold(int length) {
    if (length <= 3) return 0; // Exact match only
    if (length <= 6) return 1; // Single typo or transposition
    if (length <= 10) return 2; // Moderate variation
    return length ~/ 4; // Sublinear scaling for long phrases
  }
}

/// Universal Cross-Script Phonetic Normalizer.
///
/// Bridges Cyrillic, Latin with diacritics/umlauts, and common loanwords into
/// an Intermediate Phonetic Normal Form (IPNF) with consonant skeleton extraction.
class PhoneticNormalizer {
  const PhoneticNormalizer._();

  static final RegExp _whitespacePunctuation =
      RegExp(r"""[\s_\-\.,;:!?…\(\)\[\]"'`~@#\$%\^&\*<>/\\|+=]+""");

  /// Cyrillic-to-Phonetic-Latin transliteration lookup table.
  static const Map<String, String> _cyrillicMap = {
    'а': 'a', 'б': 'p', 'в': 'f', 'г': 'k', 'д': 't', 'е': 'e', 'ё': 'e',
    'ж': 'sh', 'з': 's', 'и': 'i', 'й': 'y', 'к': 'k', 'л': 'l', 'м': 'm',
    'н': 'n', 'о': 'o', 'п': 'p', 'р': 'r', 'с': 's', 'т': 't', 'у': 'u',
    'ф': 'f', 'х': 'k', 'ц': 'ts', 'ч': 'ch', 'ш': 'sh', 'щ': 'sh',
    'ъ': '', 'ы': 'i', 'ь': '', 'э': 'e', 'ю': 'u', 'я': 'a',
    'і': 'i', 'ї': 'i', 'є': 'e', 'ў': 'f',
  };

  /// Normalizes a phrase into its Intermediate Phonetic Normal Form (IPNF).
  ///
  /// Steps:
  /// 1. Lowercase & strip punctuation
  /// 2. Cross-script transliteration
  /// 3. Voicing neutralization (b->p, d->t, g->k, v/w/wh->f, z->s, zh->sh)
  /// 4. Affricate & digraph collapse (ph->f, th->t, kh->k, ce/ci/cy->se/si/sy, c->k, qu->k, x->ks)
  /// 5. Geminate compression (double consonants -> single)
  /// 6. Consonant skeleton extraction (preserving first letter, removing subsequent vowels)
  static String normalize(String input, {bool extractSkeleton = true}) {
    if (input.isEmpty) return '';

    final lower = input.toLowerCase().replaceAll(_whitespacePunctuation, '');
    if (lower.isEmpty) return '';

    // Step 2: Transliteration & Grapheme Mapping
    final sb = StringBuffer();
    for (var i = 0; i < lower.length; i++) {
      final char = lower[i];
      if (_cyrillicMap.containsKey(char)) {
        sb.write(_cyrillicMap[char]);
      } else {
        sb.write(_normalizeLatinDiacritics(char));
      }
    }

    var text = sb.toString();

    // Step 3 & 4: Voicing Neutralization & Affricate Collapse
    text = text
        .replaceAll('ph', 'f')
        .replaceAll('th', 't')
        .replaceAll('wh', 'f')
        .replaceAll('w', 'f')
        .replaceAll('v', 'f')
        .replaceAll('zh', 'sh')
        .replaceAll('b', 'p')
        .replaceAll('d', 't')
        .replaceAll('g', 'k')
        .replaceAll('z', 's')
        .replaceAll('ch', 'ch')
        .replaceAll('kh', 'k')
        .replaceAll('ce', 'se')
        .replaceAll('ci', 'si')
        .replaceAll('cy', 'sy')
        .replaceAll('c', 'k')
        .replaceAll('qu', 'k')
        .replaceAll('x', 'ks');

    // Step 5: Geminate Compression
    text = _collapseGeminates(text);

    // Step 6: Consonant Skeleton Extraction
    if (extractSkeleton && text.length > 1) {
      final first = text[0];
      final rest = text.substring(1).replaceAll(RegExp(r'[aeiouy]'), '');
      text = first + rest;
      text = _collapseGeminates(text);
    }

    return text;
  }

  /// Strips all whitespace, dashes, and underscores for boundary-oblivious comparison.
  static String stripWhitespace(String input) {
    return input.replaceAll(RegExp(r'[\s_\-]+'), '');
  }

  /// Checks if two strings are equivalent under phonetic normalization.
  static bool isPhoneticMatch(String a, String b) {
    if (a == b) return true;
    final normA = normalize(a);
    final normB = normalize(b);
    if (normA.isNotEmpty && normA == normB) return true;
    return false;
  }

  /// Checks if two strings are equivalent ignoring spaces, hyphens, and casing.
  static bool isAgglutinationMatch(String a, String b) {
    final cleanA = stripWhitespace(a).toLowerCase();
    final cleanB = stripWhitespace(b).toLowerCase();
    return cleanA.isNotEmpty && cleanA == cleanB;
  }

  static String _normalizeLatinDiacritics(String char) {
    switch (char) {
      case 'ä': return 'e';
      case 'ö': return 'o';
      case 'ü': return 'u';
      case 'ß': return 's';
      case 'é':
      case 'è':
      case 'ê':
      case 'ë': return 'e';
      case 'à':
      case 'á':
      case 'â':
      case 'ã':
      case 'å':
      case 'ą': return 'a';
      case 'î':
      case 'ï':
      case 'í':
      case 'ì': return 'i';
      case 'ô':
      case 'ó':
      case 'ò':
      case 'õ': return 'o';
      case 'û':
      case 'ú':
      case 'ù': return 'u';
      case 'ñ': return 'n';
      case 'ç': return 's';
      case 'ý':
      case 'ÿ': return 'y';
      case 'θ':
      case 'ϑ': return 't';
      case 'φ':
      case 'ϕ': return 'f';
      case 'χ': return 'k';
      case 'ψ': return 'ps';
      case 'ξ': return 'ks';
      default: return char;
    }
  }

  static String _collapseGeminates(String input) {
    if (input.length <= 1) return input;
    final out = StringBuffer()..write(input[0]);
    for (var i = 1; i < input.length; i++) {
      if (input[i] != input[i - 1]) {
        out.write(input[i]);
      }
    }
    return out.toString();
  }
}
