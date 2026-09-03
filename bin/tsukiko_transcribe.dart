import 'dart:io';

import 'package:tsukiko/cli/transcribe.dart' as cli;

/// Точка входа `tsukiko-transcribe`. Само дело — в `lib/cli/transcribe.dart`:
/// оттуда его видно тестам, а из `bin/` — нет.
Future<void> main(List<String> args) async => exit(await cli.run(args));
