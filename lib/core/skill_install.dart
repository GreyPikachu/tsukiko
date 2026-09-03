import 'dart:io';

import '../platform/os.dart';

/// Установка скилла тем нейросетевым агентам, которые действительно стоят
/// на этой машине.
///
/// «Действительно стоят» — здесь главное слово. Разложить папку во все
/// известные места было бы проще, но так не делают: у человека с одним
/// Codex появились бы `~/.openclaw/skills/` и `~/.hermes/skills/`
/// на пустом месте, и он справедливо решил бы, что программа сорит
/// в его домашней папке.
///
/// Признаки взяты из `vercel-labs/skills` (MIT) — там же, где их берёт
/// `npx skills add`: агент считается установленным, если есть его папка
/// настроек. Своей выдумки здесь нет намеренно: разойтись с общепринятым
/// значило бы то не находить установленное, то находить лишнее.

/// Куда один агент кладёт скиллы и по чему его узнают.
class AgentTarget {
  const AgentTarget(
    this.id,
    this.name, {
    required this.candidates,
    this.envHome,
  });

  final String id, name;

  /// Переменная окружения, которой человек мог перенести настройки
  /// в другое место. Она важнее умолчания: без неё у того, кто
  /// перенёс папку, агент считался бы не установленным.
  final String? envHome;

  /// Папки настроек, любая из которых значит «агент стоит». Списком,
  /// а не одной: инструменты переименовываются, и люди с прежней папкой
  /// не должны отваливаться.
  final List<List<String>> candidates;

  /// Папка настроек этого агента или null, если его тут нет.
  String? configDir() {
    final env = envHome == null ? null : Platform.environment[envHome!]?.trim();
    if (env != null && env.isNotEmpty && Directory(env).existsSync()) return env;
    for (final parts in candidates) {
      final path = parts.fold(os.home, (String at, String part) => os.join(at, part));
      if (Directory(path).existsSync()) return path;
    }
    return null;
  }

  /// Куда лёг бы наш скилл. null — агента нет.
  String? skillDir() {
    final config = configDir();
    return config == null ? null : os.join(config, 'skills', appName);
  }
}

/// Агенты, которые понимают скиллы в общем формате `SKILL.md`.
///
/// Список намеренно короткий: те, у кого формат тот же и папка известна.
/// Остальным скилл ставится руками — на этот случай в репозитории лежит
/// `skills/tsukiko/README.md` с таблицей путей.
const skillAgents = [
  AgentTarget('claude-code', 'Claude Code',
      envHome: 'CLAUDE_CONFIG_DIR', candidates: [['.claude']]),
  AgentTarget('codex', 'Codex', envHome: 'CODEX_HOME', candidates: [['.codex']]),
  AgentTarget('antigravity', 'Antigravity',
      candidates: [['.gemini', 'antigravity']]),
  // Переименовывался дважды; у людей с прежней установкой лежит старая папка.
  AgentTarget('openclaw', 'OpenClaw',
      candidates: [['.openclaw'], ['.clawdbot'], ['.moltbot']]),
  AgentTarget('hermes', 'Hermes', envHome: 'HERMES_HOME', candidates: [['.hermes']]),
  AgentTarget('opencode', 'OpenCode', candidates: [['.config', 'opencode']]),
];

/// Что стало с одним агентом при установке.
enum SkillOutcome {
  /// Положили или обновили.
  installed,

  /// Там уже лежит чужой скилл с таким же именем. Не трогаем: затереть
  /// чужую работу хуже, чем не поставить свою.
  foreign,

  /// Не вышло записать — нет прав, диск полон.
  failed,
}

/// Поставить скилл выбранным агентам. Возвращает, что с кем стало.
///
/// [text] — содержимое `SKILL.md`; оно едет внутри приложения, поэтому
/// поставленный скилл всегда той же версии, что и программа, которую он
/// зовёт. Скачанный из репозитория мог бы знать про ключи, которых
/// в установленном движке ещё нет.
Map<String, SkillOutcome> installSkill(
  Iterable<AgentTarget> targets,
  String text,
) {
  final out = <String, SkillOutcome>{};
  for (final agent in targets) {
    final dir = agent.skillDir();
    if (dir == null) continue;
    try {
      final file = File(os.join(dir, 'SKILL.md'));
      if (file.existsSync() && !isOurSkill(file.readAsStringSync())) {
        out[agent.id] = SkillOutcome.foreign;
        continue;
      }
      Directory(dir).createSync(recursive: true);
      file.writeAsStringSync(text);
      out[agent.id] = SkillOutcome.installed;
    } catch (_) {
      out[agent.id] = SkillOutcome.failed;
    }
  }
  return out;
}

/// Наш ли это скилл. Смотрим на имя в шапке: совпало имя папки, но внутри
/// чужое — значит место занято кем-то другим.
bool isOurSkill(String text) =>
    RegExp('^name:\\s*$appName\\s*\$', multiLine: true).hasMatch(text);
