import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:maid_kit/data/local/app_database.dart';

/// Editable description of a local MCP server. [arguments] and [environment]
/// are stored JSON-encoded so the schema can evolve without migrations.
class McpServerDraft {
  const McpServerDraft({
    required this.name,
    required this.command,
    required this.arguments,
    required this.environment,
    this.enabled = true,
  });

  final String name;
  final String command;
  final List<String> arguments;
  final Map<String, String> environment;
  final bool enabled;
}

/// Decodes the JSON array of launch arguments stored on an [McpServer] row.
List<String> decodeMcpArguments(String raw) {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    return const [];
  }
  if (decoded is! List) return const [];
  return [
    for (final item in decoded)
      if (item is String) item,
  ];
}

/// Decodes the JSON object of environment overrides stored on an [McpServer]
/// row. Values are merged over the app's own environment at launch.
Map<String, String> decodeMcpEnvironment(String raw) {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    return const {};
  }
  if (decoded is! Map) return const {};
  return {
    for (final entry in decoded.entries)
      if (entry.key is String && entry.value is String)
        entry.key as String: entry.value as String,
  };
}

class McpRepository {
  McpRepository(this._database);

  final AppDatabase _database;

  Stream<List<McpServer>> watchAll() => _database.watchMcpServers();

  Future<List<McpServer>> all() => (_database.select(
    _database.mcpServers,
  )..orderBy([(table) => OrderingTerm.asc(table.name)])).get();

  Future<McpServer?> server(int id) => (_database.select(
    _database.mcpServers,
  )..where((table) => table.id.equals(id))).getSingleOrNull();

  Future<int> save(McpServerDraft draft, {int? id}) async {
    final name = draft.name.trim();
    final command = draft.command.trim();
    if (name.isEmpty || command.isEmpty) {
      throw ArgumentError('An MCP server needs a name and a launch command.');
    }
    final now = DateTime.now().toUtc();
    final arguments = jsonEncode(draft.arguments);
    final environment = jsonEncode(draft.environment);
    if (id == null) {
      return _database
          .into(_database.mcpServers)
          .insert(
            McpServersCompanion.insert(
              name: name,
              command: command,
              arguments: Value(arguments),
              environment: Value(environment),
              enabled: Value(draft.enabled),
              createdAt: now,
              updatedAt: now,
            ),
          );
    }
    await (_database.update(
      _database.mcpServers,
    )..where((table) => table.id.equals(id))).write(
      McpServersCompanion(
        name: Value(name),
        command: Value(command),
        arguments: Value(arguments),
        environment: Value(environment),
        enabled: Value(draft.enabled),
        updatedAt: Value(now),
      ),
    );
    return id;
  }

  Future<void> setEnabled(int id, bool enabled) =>
      (_database.update(
        _database.mcpServers,
      )..where((table) => table.id.equals(id))).write(
        McpServersCompanion(
          enabled: Value(enabled),
          updatedAt: Value(DateTime.now().toUtc()),
        ),
      );

  Future<void> delete(int id) => (_database.delete(
    _database.mcpServers,
  )..where((table) => table.id.equals(id))).go();
}
