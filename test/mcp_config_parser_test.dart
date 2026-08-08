import 'package:flutter_test/flutter_test.dart';

import 'package:maid_kit/agent/mcp_config_parser.dart';
import 'package:maid_kit/agent/mcp_repository.dart';

void main() {
  group('parseMcpConfigJson', () {
    test('parses a VS Code style config', () {
      final result = parseMcpConfigJson('''
{
  "servers": {
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/Users/me"],
      "env": {"API_KEY": "abc123"}
    },
    "github": {
      "command": "node",
      "args": ["/opt/mcp/github.js"]
    }
  }
}
''');
      expect(result.hasErrors, isFalse);
      expect(result.servers, hasLength(2));

      final filesystem = result.servers[0];
      expect(filesystem.name, 'filesystem');
      expect(filesystem.command, 'npx');
      expect(filesystem.arguments, [
        '-y',
        '@modelcontextprotocol/server-filesystem',
        '/Users/me',
      ]);
      expect(filesystem.environment, {'API_KEY': 'abc123'});

      final github = result.servers[1];
      expect(github.arguments, ['/opt/mcp/github.js']);
      expect(github.environment, isEmpty);
    });

    test('parses a Claude Desktop style config', () {
      final result = parseMcpConfigJson('''
{"mcpServers": {"web": {"command": "uvx", "args": ["mcp-server-web"], "env": {}}}}
''');
      expect(result.hasErrors, isFalse);
      expect(result.servers.single.name, 'web');
      expect(result.servers.single.command, 'uvx');
    });

    test('coerces non-string env values to strings', () {
      final result = parseMcpConfigJson('''
{"servers": {"a": {"command": "x", "env": {"PORT": 8080, "FLAG": true}}}}
''');
      expect(result.hasErrors, isFalse);
      expect(result.servers.single.environment, {
        'PORT': '8080',
        'FLAG': 'true',
      });
    });

    test('reports invalid JSON', () {
      final result = parseMcpConfigJson('{ not json');
      expect(result.servers, isEmpty);
      expect(result.errors.single, startsWith('Invalid JSON'));
    });

    test('rejects non-object roots and missing server maps', () {
      expect(parseMcpConfigJson('[1,2]').errors.single, contains('object'));
      expect(
        parseMcpConfigJson('{"other": {}}').errors.single,
        contains('servers'),
      );
      expect(parseMcpConfigJson('   ').errors.single, contains('empty'));
    });

    test('imports valid entries while reporting broken ones', () {
      final result = parseMcpConfigJson('''
{
  "servers": {
    "good": {"command": "npx", "args": ["-y", "@x/y"]},
    "noCommand": {"args": []},
    "httpOnly": {"type": "http", "url": "https://example.com/mcp"},
    "badArgs": {"command": "npx", "args": "not-a-list"},
    "badEnv": {"command": "npx", "env": ["a"]},
    "notAnObject": "npx"
  }
}
''');
      expect(result.servers, hasLength(1));
      expect(result.servers.single.name, 'good');
      expect(result.errors, hasLength(5));
      expect(result.errors.join('\n'), contains('noCommand'));
      expect(result.errors.join('\n'), contains('only stdio'));
      expect(result.errors.join('\n'), contains('badArgs'));
      expect(result.errors.join('\n'), contains('badEnv'));
      expect(result.errors.join('\n'), contains('notAnObject'));
    });

    test('drafts are ready to save through the repository', () {
      final result = parseMcpConfigJson(
        '{"servers": {"a": {"command": "cmd", "args": [], "env": {}}}}',
      );
      final draft = result.servers.single;
      expect(draft, isA<McpServerDraft>());
      expect(draft.enabled, isTrue);
    });
  });
}
