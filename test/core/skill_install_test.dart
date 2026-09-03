import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiko/core/skill_install.dart';
import 'package:tsukiko/platform/os.dart';

import '../support/fake_os.dart';

/// Установка скилла. Проверяется то, ради чего это писалось: не сорить
/// в домашней папке и не затирать чужое.
void main() {
  useTempSupportDir('tsukiko-skill');

  const skill = '---\nname: tsukiko\ndescription: расшифровка\n---\n\nтело';

  Directory dir(List<String> parts) =>
      Directory(parts.fold(os.home, (String at, String p) => os.join(at, p)));

  test('ставим только тем, кто действительно стоит', () {
    dir(['.claude']).createSync(recursive: true);
    dir(['.gemini', 'antigravity']).createSync(recursive: true);

    final found = skillAgents.where((a) => a.configDir() != null).toList();
    expect(found.map((a) => a.id), ['claude-code', 'antigravity']);

    installSkill(found, skill);

    // Главное: у того, кто поставил один Codex, не должно появиться
    // ни `.openclaw`, ни `.hermes` — папок «на всякий случай» не бывает.
    final laid = os.join(os.join(os.home, '.claude', 'skills'), 'tsukiko', 'SKILL.md');
    expect(File(laid).existsSync(), isTrue);
    expect(dir(['.openclaw']).existsSync(), isFalse);
    expect(dir(['.hermes']).existsSync(), isFalse);
    expect(dir(['.codex']).existsSync(), isFalse);
  });

  test('переименованная папка агента тоже считается установкой', () {
    // OpenClaw звался и .clawdbot, и .moltbot. Человек с прежней папкой
    // не должен оказаться «без агента».
    dir(['.moltbot']).createSync(recursive: true);
    final openclaw = skillAgents.firstWhere((a) => a.id == 'openclaw');
    expect(openclaw.configDir(), os.join(os.home, '.moltbot'));
  });

  test('чужой скилл под тем же именем не затирается', () {
    final at = Directory(os.join(os.join(os.home, '.claude', 'skills'), 'tsukiko'))
      ..createSync(recursive: true);
    final file = File(os.join(at.path, 'SKILL.md'))
      ..writeAsStringSync('---\nname: чужой\n---\nне трогать');

    dir(['.claude']).createSync(recursive: true);
    final claude = skillAgents.firstWhere((a) => a.id == 'claude-code');
    final result = installSkill([claude], skill);

    expect(result['claude-code'], SkillOutcome.foreign);
    expect(file.readAsStringSync(), contains('не трогать'));
  });

  test('свой скилл обновляется молча', () {
    dir(['.claude']).createSync(recursive: true);
    final claude = skillAgents.firstWhere((a) => a.id == 'claude-code');
    expect(installSkill([claude], skill)['claude-code'], SkillOutcome.installed);
    // Второй заход поверх своего же — это обновление, а не занятое место.
    expect(installSkill([claude], skill)['claude-code'], SkillOutcome.installed);
  });

  test('перенесённые настройки находятся по переменной окружения', () {
    // Без этого человек, перенёсший ~/.claude, считался бы без агента.
    expect(skillAgents.firstWhere((a) => a.id == 'claude-code').envHome,
        'CLAUDE_CONFIG_DIR');
    expect(skillAgents.firstWhere((a) => a.id == 'codex').envHome, 'CODEX_HOME');
  });
}
