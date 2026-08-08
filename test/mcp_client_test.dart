import 'dart:async';
import 'dart:convert';

import 'package:dart_openai/dart_openai.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:maid_kit/agent/mcp_client.dart';
import 'package:maid_kit/agent/mcp_repository.dart';
import 'package:maid_kit/agent/ssh_agent_service.dart';

/// In-memory transport that records outgoing JSON-RPC messages and lets the
/// test inject server responses line by line.
class _FakeMcpTransport implements McpTransport {
  final sent = <String>[];
  final _controller = StreamController<String>();

  @override
  Stream<String> get incoming => _controller.stream;

  @override
  void send(String message) => sent.add(message);

  @override
  Future<void> close() async => _controller.close();

  void emit(Object message) => _controller.add(jsonEncode(message));
}

/// Lets pending microtasks and stream events settle before assertions.
Future<void> _flush() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Completes the MCP initialize handshake on [transport] for [client].
Future<void> _handshake(McpClient client, _FakeMcpTransport transport) async {
  final done = client.initialize();
  await _flush();
  final initialize = jsonDecode(transport.sent[0]) as Map<String, dynamic>;
  expect(initialize['method'], 'initialize');
  transport.emit({
    'jsonrpc': '2.0',
    'id': initialize['id'],
    'result': {
      'protocolVersion': mcpProtocolVersion,
      'capabilities': <String, Object?>{},
      'serverInfo': {'name': 'fake', 'version': '1.0.0'},
    },
  });
  await done;
  await _flush();
  final initialized = jsonDecode(transport.sent[1]) as Map<String, dynamic>;
  expect(initialized['method'], 'notifications/initialized');
}

/// Returns the id of the last request sent over [transport].
int _lastRequestId(_FakeMcpTransport transport) {
  final message = jsonDecode(transport.sent.last) as Map<String, dynamic>;
  return message['id'] as int;
}

void main() {
  group('McpClient over stdio-style transport', () {
    test(
      'initialize sends the handshake and the initialized notification',
      () async {
        final transport = _FakeMcpTransport();
        final client = McpClient(transport);
        await _handshake(client, transport);
        await client.dispose();
      },
    );

    test('listTools parses tool definitions and caches them', () async {
      final transport = _FakeMcpTransport();
      final client = McpClient(transport);
      await _handshake(client, transport);

      final first = client.listTools();
      await _flush();
      transport.emit({
        'jsonrpc': '2.0',
        'id': _lastRequestId(transport),
        'result': {
          'tools': [
            {
              'name': 'read_file',
              'description': 'Read a file',
              'inputSchema': {
                'type': 'object',
                'properties': {
                  'path': {'type': 'string'},
                },
                'required': ['path'],
              },
            },
            {'name': 'ignored_without_schema'},
          ],
        },
      });
      final tools = await first;
      expect(tools, hasLength(2));
      expect(tools.first.name, 'read_file');
      expect(tools.first.inputSchema['required'], contains('path'));
      // A tool without an input schema is still exposed (empty schema).
      expect(tools.last.name, 'ignored_without_schema');

      // The cached list is returned without another tools/list request.
      final before = transport.sent.length;
      final cached = await client.listTools();
      expect(transport.sent.length, before);
      expect(cached, same(tools));

      // tools/list_changed invalidates the cache.
      transport.emit({
        'jsonrpc': '2.0',
        'method': 'notifications/tools/list_changed',
      });
      await _flush();
      final refreshed = client.listTools();
      await _flush();
      expect(
        (jsonDecode(transport.sent.last) as Map<String, dynamic>)['method'],
        'tools/list',
      );
      transport.emit({
        'jsonrpc': '2.0',
        'id': _lastRequestId(transport),
        'result': {'tools': []},
      });
      expect(await refreshed, isEmpty);
      await client.dispose();
    });

    test(
      'callTool sends arguments and renders text and image content',
      () async {
        final transport = _FakeMcpTransport();
        final client = McpClient(transport);
        await _handshake(client, transport);

        final call = client.callTool('echo', {'text': 'hello'});
        await _flush();
        final request = jsonDecode(transport.sent.last) as Map<String, dynamic>;
        expect(request['method'], 'tools/call');
        expect(request['params'], {
          'name': 'echo',
          'arguments': {'text': 'hello'},
        });
        transport.emit({
          'jsonrpc': '2.0',
          'id': request['id'],
          'result': {
            'content': [
              {'type': 'text', 'text': 'line one\nline two'},
              {'type': 'image', 'mimeType': 'image/png', 'data': 'aGVsbG8='},
            ],
          },
        });
        final result = await call;
        expect(result.isError, isFalse);
        expect(result.text, 'line one\nline two\n[image (image/png)]');
        expect(result.content, hasLength(2));
        await client.dispose();
      },
    );

    test('callTool surfaces server errors as McpException', () async {
      final transport = _FakeMcpTransport();
      final client = McpClient(transport);
      await _handshake(client, transport);

      final call = client.callTool('boom', const {});
      await _flush();
      transport.emit({
        'jsonrpc': '2.0',
        'id': _lastRequestId(transport),
        'error': {'code': -32601, 'message': 'Unknown tool: boom'},
      });
      await expectLater(
        call,
        throwsA(
          isA<McpException>().having(
            (error) => error.message,
            'message',
            contains('Unknown tool'),
          ),
        ),
      );
      await client.dispose();
    });

    test('a cancelled token aborts the call and notifies the server', () async {
      final transport = _FakeMcpTransport();
      final client = McpClient(transport);
      await _handshake(client, transport);

      final token = AgentCancelToken();
      final call = client.callTool('slow', const {}, cancelToken: token);
      await _flush();
      token.cancel();
      await expectLater(call, throwsA(isA<AgentCancelledException>()));
      await _flush();
      final cancelled = jsonDecode(transport.sent.last) as Map<String, dynamic>;
      expect(cancelled['method'], 'notifications/cancelled');
      await client.dispose();
    });

    test('server close fails in-flight requests', () async {
      final transport = _FakeMcpTransport();
      final client = McpClient(transport);
      await _handshake(client, transport);

      final call = client.callTool('long', const {});
      await _flush();
      await transport.close();
      await expectLater(call, throwsA(isA<McpException>()));
    });
  });

  group('MCP tool schema projection', () {
    test('withSafeToRunProperty extends plain object schemas only', () {
      final extended = withSafeToRunProperty(const {
        'type': 'object',
        'properties': {
          'path': {'type': 'string'},
        },
      });
      expect(extended, isNotNull);
      final safeToRun = (extended!['properties'] as Map)['safe_to_run'];
      expect((safeToRun as Map)['type'], 'boolean');

      expect(
        withSafeToRunProperty(const {'type': 'array'}),
        isNull,
        reason: 'non-object schemas cannot be extended safely',
      );
      expect(
        withSafeToRunProperty(const {'type': 'object'}),
        isNull,
        reason: 'schemas without a properties map cannot be extended',
      );
    });

    test('targets project to OpenAI tools with qualified names', () {
      final target = AgentMcpToolTarget(
        serverId: 3,
        serverName: 'Files',
        name: 'read_file',
        description: 'Read a file',
        inputSchema: const {
          'type': 'object',
          'properties': {
            'path': {'type': 'string'},
          },
        },
      );
      expect(target.qualifiedName, 'mcp_3__read_file');
      expect(AgentMcpToolTarget.bareName(target.qualifiedName), 'read_file');

      final map = target.toOpenAiToolMap();
      final function = map['function'] as Map;
      expect(map['type'], 'function');
      expect(function['name'], 'mcp_3__read_file');
      expect(function['description'], contains('Files'));
      expect(
        ((function['parameters'] as Map)['properties'] as Map),
        contains('safe_to_run'),
      );
    });

    test('proposal derives the mcp server id from the tool name', () {
      final call = OpenAIResponseToolCall.fromMap({
        'id': 'call_1',
        'type': 'function',
        'function': {
          'name': 'mcp_12__read_file',
          'arguments': '{"path":"/tmp/x","safe_to_run":true}',
        },
      });
      final message = OpenAIChatCompletionChoiceMessageModel(
        role: OpenAIChatMessageRole.assistant,
        content: null,
        toolCalls: [call],
      );
      final proposal = AgentProposal(
        kind: AgentActionKind.mcpToolCall,
        arguments: const {'path': '/tmp/x', 'safe_to_run': true},
        toolCall: call,
        assistantMessage: message,
      );
      expect(proposal.mcpServerId, 12);
      expect(proposal.safeToRun, isTrue);
      expect(proposal.detail, contains('mcp_12__read_file'));
    });
  });

  group('MCP repository encoding', () {
    test('decodeMcpArguments and decodeMcpEnvironment handle bad payloads', () {
      expect(decodeMcpArguments('["a","b"]'), ['a', 'b']);
      expect(decodeMcpArguments('not json'), isEmpty);
      expect(decodeMcpArguments('{"a":1}'), isEmpty);
      expect(decodeMcpEnvironment('{"K":"v"}'), {'K': 'v'});
      expect(decodeMcpEnvironment('[1]'), isEmpty);
      expect(decodeMcpEnvironment('nope'), isEmpty);
    });
  });
}
