import 'dart:async';
import 'dart:typed_data';

import 'package:dart_openai/dart_openai.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:dartssh2/src/ssh_channel.dart'
    show SSHChannel, SSHChannelController;
import 'package:flutter_test/flutter_test.dart';
import 'package:maid_kit/agent/ssh_agent_service.dart';

void main() {
  test('closes the SFTP channel after a file action', () async {
    var closed = 0;
    final sftp = _RecordingSftpClient(() => closed++);
    final client = _FakeSshClient(sftp);
    final proposal = AgentProposal(
      kind: AgentActionKind.deleteFile,
      arguments: {'path': '/tmp/old-file'},
      toolCall: OpenAIResponseToolCall.fromMap({
        'id': 'call-1',
        'type': 'function',
        'function': {'name': 'delete_file', 'arguments': '{}'},
      }),
      assistantMessage: const OpenAIChatCompletionChoiceMessageModel(
        role: OpenAIChatMessageRole.assistant,
        content: null,
      ),
    );

    addTearDown(client.close);
    final result = await SshAgentService.executeProposal(client, proposal);

    expect(result, 'Deleted /tmp/old-file');
    expect(closed, 1);
  });
}

class _FakeSshClient extends SSHClient {
  _FakeSshClient(this._sftp)
    : super(
        _FakeSshSocket(),
        username: 'test',
        keepAliveInterval: null,
        authTimeout: const Duration(days: 1),
      );

  final SftpClient _sftp;

  @override
  Future<SftpClient> sftp() async => _sftp;
}

class _RecordingSftpClient extends SftpClient {
  _RecordingSftpClient(this._onClose) : super(_channel());

  final void Function() _onClose;

  static SSHChannel _channel() {
    return SSHChannelController(
      localId: 0,
      localMaximumPacketSize: 32 * 1024,
      localInitialWindowSize: 2 * 1024 * 1024,
      remoteId: 0,
      remoteMaximumPacketSize: 32 * 1024,
      remoteInitialWindowSize: 2 * 1024 * 1024,
      sendMessage: (_) {},
    ).channel;
  }

  @override
  Future<void> remove(String filename) async {}

  @override
  Future<void> close() async => _onClose();
}

class _FakeSshSocket implements SSHSocket {
  final _incoming = StreamController<Uint8List>();
  final _outgoing = StreamController<List<int>>();

  @override
  Stream<Uint8List> get stream => _incoming.stream;

  @override
  StreamSink<List<int>> get sink => _outgoing.sink;

  @override
  Future<void> get done => Completer<void>().future;

  @override
  Future<void> close() async {
    await _incoming.close();
    await _outgoing.close();
  }

  @override
  Future<void> flush() async {}

  @override
  void destroy() {
    unawaited(close());
  }
}
