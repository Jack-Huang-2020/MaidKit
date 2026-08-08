import 'dart:convert';

import 'mcp_repository.dart';

/// Result of parsing a pasted MCP server config. Parsing is lenient: valid
/// servers are returned alongside human-readable errors for the entries that
/// could not be imported, so a mostly-good config still imports.
class McpConfigParseResult {
  const McpConfigParseResult({required this.servers, required this.errors});

  final List<McpServerDraft> servers;
  final List<String> errors;

  bool get hasErrors => errors.isNotEmpty;
}

/// Parses a VS Code (`.vscode/mcp.json`) or Claude Desktop style MCP config:
///
/// ```json
/// {
///   "servers": {
///     "filesystem": {
///       "command": "npx",
///       "args": ["-y", "@modelcontextprotocol/server-filesystem", "/Users/me"],
///       "env": {"API_KEY": "value"}
///     }
///   }
/// }
/// ```
///
/// Both the `servers` (VS Code, Cline) and `mcpServers` (Claude Desktop)
/// top-level keys are accepted. Only stdio servers are supported; entries
/// with another `type` are reported and skipped.
McpConfigParseResult parseMcpConfigJson(String source) {
  if (source.trim().isEmpty) {
    return const McpConfigParseResult(
      servers: [],
      errors: ['Config is empty.'],
    );
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(source);
  } catch (error) {
    return McpConfigParseResult(
      servers: const [],
      errors: ['Invalid JSON: $error'],
    );
  }
  if (decoded is! Map<String, dynamic>) {
    return const McpConfigParseResult(
      servers: [],
      errors: ['Config must be a JSON object.'],
    );
  }
  final servers = decoded['servers'] ?? decoded['mcpServers'];
  if (servers is! Map<String, dynamic>) {
    return const McpConfigParseResult(
      servers: [],
      errors: ['No "servers" or "mcpServers" object found.'],
    );
  }
  final drafts = <McpServerDraft>[];
  final errors = <String>[];
  for (final entry in servers.entries) {
    final name = entry.key.trim();
    final value = entry.value;
    if (name.isEmpty) {
      errors.add('Server entry has an empty name.');
      continue;
    }
    if (value is! Map<String, dynamic>) {
      errors.add('Server "$name": expected an object.');
      continue;
    }
    final type = value['type'];
    if (type is String && type != 'stdio') {
      errors.add(
        'Server "$name": only stdio servers are supported (got "$type").',
      );
      continue;
    }
    final command = value['command'];
    if (command is! String || command.trim().isEmpty) {
      errors.add('Server "$name": missing a command.');
      continue;
    }
    final rawArgs = value['args'];
    final List<String> arguments;
    if (rawArgs == null) {
      arguments = const [];
    } else if (rawArgs is List && rawArgs.every((item) => item is String)) {
      arguments = rawArgs.cast<String>();
    } else {
      errors.add('Server "$name": args must be an array of strings.');
      continue;
    }
    final rawEnv = value['env'];
    final Map<String, String> environment;
    if (rawEnv == null) {
      environment = const {};
    } else if (rawEnv is Map && rawEnv.keys.every((key) => key is String)) {
      // Configs occasionally carry non-string env values; coerce them so a
      // pasted config still imports.
      environment = {
        for (final envEntry in rawEnv.entries)
          envEntry.key as String: '${envEntry.value}',
      };
    } else {
      errors.add('Server "$name": env must be an object of string values.');
      continue;
    }
    drafts.add(
      McpServerDraft(
        name: name,
        command: command.trim(),
        arguments: arguments,
        environment: environment,
      ),
    );
  }
  return McpConfigParseResult(servers: drafts, errors: errors);
}
