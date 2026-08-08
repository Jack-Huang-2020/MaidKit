import 'package:drift/drift.dart';
import 'package:maid_kit/data/local/app_database.dart';

/// Editable description of a skill the agent can consult. [content] is plain
/// markdown and intentionally bounded so a single `get_skill` result stays
/// small enough for the model's context window.
class AgentSkillDraft {
  const AgentSkillDraft({
    required this.name,
    required this.description,
    required this.content,
    this.enabled = true,
  });

  final String name;
  final String description;
  final String content;
  final bool enabled;
}

class SkillRepository {
  SkillRepository(this._database);

  final AppDatabase _database;

  /// Largest skill payload handed to the model. Keeps the system prompt and
  /// `get_skill` results bounded regardless of how many skills are saved.
  /// Sized to fit the largest skill in Vercel's official registry.
  static const int maxContentLength = 32768;

  Stream<List<AgentSkill>> watchAll() => _database.watchAgentSkills();

  Future<List<AgentSkill>> all() => (_database.select(
    _database.agentSkills,
  )..orderBy([(table) => OrderingTerm.asc(table.name)])).get();

  Future<AgentSkill?> skill(int id) => (_database.select(
    _database.agentSkills,
  )..where((table) => table.id.equals(id))).getSingleOrNull();

  Future<int> save(AgentSkillDraft draft, {int? id}) async {
    final name = draft.name.trim();
    final content = draft.content.trim();
    if (name.isEmpty || content.isEmpty) {
      throw ArgumentError('A skill needs a name and content.');
    }
    if (content.length > maxContentLength) {
      throw ArgumentError(
        'Skill content is limited to $maxContentLength characters.',
      );
    }
    final now = DateTime.now().toUtc();
    if (id == null) {
      return _database
          .into(_database.agentSkills)
          .insert(
            AgentSkillsCompanion.insert(
              name: name,
              description: Value(draft.description.trim()),
              content: content,
              enabled: Value(draft.enabled),
              createdAt: now,
              updatedAt: now,
            ),
          );
    }
    await (_database.update(
      _database.agentSkills,
    )..where((table) => table.id.equals(id))).write(
      AgentSkillsCompanion(
        name: Value(name),
        description: Value(draft.description.trim()),
        content: Value(content),
        enabled: Value(draft.enabled),
        updatedAt: Value(now),
      ),
    );
    return id;
  }

  Future<void> setEnabled(int id, bool enabled) =>
      (_database.update(
        _database.agentSkills,
      )..where((table) => table.id.equals(id))).write(
        AgentSkillsCompanion(
          enabled: Value(enabled),
          updatedAt: Value(DateTime.now().toUtc()),
        ),
      );

  Future<void> delete(int id) => (_database.delete(
    _database.agentSkills,
  )..where((table) => table.id.equals(id))).go();
}
