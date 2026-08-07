import 'dart:convert';
import 'dart:io';

import 'package:async/async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:maid_kit/servers/serial_bridge_client.dart';
import 'package:maid_kit/servers/server_models.dart';

/// End-to-end test of the serial bridge protocol: the Dart [SerialBridgeClient]
/// talks to the actual compiled Swift helper binary over loopback TCP, and the
/// helper bridges bytes to a real pty standing in for a serial device.
///
/// The helper is compiled on the fly from macos/SerialBridge/SerialBridge.swift
/// (the same source the Xcode build phase produces). Platform channels are the
/// only mocks: the method channel reports `enabled`, and path_provider points
/// at a temp directory that both the test and the helper can reach.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory rendezvousDir;
  late Process helperProcess;
  late String bundleId;

  setUpAll(() async {
    // Compile the real helper from source, exactly as the Xcode phase does.
    final source = File('macos/SerialBridge/SerialBridge.swift');
    if (!source.existsSync()) {
      fail('macos/SerialBridge/SerialBridge.swift missing');
    }
    final binary = File(
      '${Directory.systemTemp.createTempSync('serial-bridge-').path}/serial-bridge',
    );
    final compile = await Process.run('xcrun', [
      '--sdk',
      'macosx',
      'swiftc',
      '-O',
      '-target',
      '${Platform.localHostname.contains('x86') ? 'x86_64' : 'arm64'}-apple-macos10.15',
      '-o',
      binary.path,
      source.path,
    ]);
    if (compile.exitCode != 0) {
      fail('helper compile failed:\n${compile.stderr}');
    }
    // Keep the binary for the whole suite; only the first test compiles.
    await Process.run('chmod', ['+x', binary.path]);
    // Make the compiled helper visible to later tests via an env-style lookup.
    rendezvousDir = Directory.systemTemp.createTempSync('serial-rdv-');
    bundleId = 'test.maidkit.serial';
    helperProcess = await Process.start(binary.path, [bundleId]);
    // The helper writes to <home>/Library/Application Support/<bundle>/… so a
    // plain temp dir would not be hit; instead we mock path_provider to the
    // same directory so the client and helper agree.
    final container = Directory(
      '${Platform.environment['HOME']}/Library/Application Support/$bundleId',
    );
    await container.create(recursive: true);
    rendezvousDir = container;
    // Wait for the rendezvous file the helper publishes at startup.
    final rendezvousFile = File('${rendezvousDir.path}/serial-bridge.json');
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!rendezvousFile.existsSync()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('helper never published its rendezvous file');
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  });

  tearDownAll(() {
    helperProcess.kill();
    // Clean up the synthetic support directory so repeated runs start fresh.
    Directory(
      '${Platform.environment['HOME']}/Library/Application Support/$bundleId',
    ).deleteSync(recursive: true);
  });

  /// Points path_provider at the same directory the helper writes into.
  void mockPathProvider(Directory dir) {
    PathProviderPlatform.instance = _FakePathProvider(dir);
  }

  /// Reports the helper as registered so the client skips to connecting.
  void mockBridgeChannelEnabled() {
    const channel = MethodChannel(SerialBridgeClient.channelName);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'ensureRegistered') return 'enabled';
          return null;
        });
  }

  test(
    'client opens a device through the real helper and relays bytes',
    () async {
      mockPathProvider(rendezvousDir);
      mockBridgeChannelEnabled();

      // A pty stands in for /dev/cu.*; the slave side is what the helper opens.
      final (bridge, slaveName) = await _PtyBridge.start();
      addTearDown(() async {
        await bridge.close();
      });

      final client = SerialBridgeClient();
      final session = await client.open(
        SerialConfig(
          device: slaveName,
          baudRate: 115200,
          dataBits: 8,
          parity: SerialParity.none,
          stopBits: 1,
          flowControl: SerialFlowControl.none,
        ),
      );

      // App -> device.
      session.write(utf8.encode('hello device\n'));
      final receivedHex = await bridge.read(13);
      expect(utf8.decode(_hexToBytes(receivedHex)), 'hello device\n');

      // Device -> app.
      await bridge.write(utf8.encode('hello app\n'));
      final fromDevice = await session.bytes.first;
      expect(utf8.decode(fromDevice), 'hello app\n');

      // Device EOF ends the session (helper closes the socket).
      await bridge.close();
      await session.done.timeout(const Duration(seconds: 10));
    },
  );

  test('client lists devices through the real helper', () async {
    mockPathProvider(rendezvousDir);
    mockBridgeChannelEnabled();

    final client = SerialBridgeClient();
    final devices = await client.listDevices();
    // The enumeration returns whatever /dev/cu.* ports exist on this machine
    // (the test's pty is /dev/ttys*, never listed), and the helper's own
    // discovery proves the LIST round trip parses as a JSON string list.
    expect(devices, isA<List<String>>());
    expect(
      devices,
      isNot(contains(anyOf(contains('/dev/ttys'), contains('/dev/tty.')))),
    );
    // Paths must be absolute device names.
    for (final device in devices) {
      expect(device, startsWith('/dev/'));
      expect(device, isNot(contains(' ')));
    }
  });

  test('client rejects an invalid token', () async {
    mockPathProvider(rendezvousDir);
    mockBridgeChannelEnabled();

    // Connect manually, send a wrong AUTH line, expect an ERR reply.
    final rendezvous = File('${rendezvousDir.path}/serial-bridge.json');
    final info =
        jsonDecode(await rendezvous.readAsString()) as Map<String, dynamic>;
    final socket = await Socket.connect('127.0.0.1', info['port'] as int);
    addTearDown(socket.destroy);
    socket.add(utf8.encode('AUTH wrong-token\n'));
    final line = await socket
        .cast<List<int>>()
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first
        .timeout(const Duration(seconds: 5));
    expect(line, startsWith('ERR '));
  });

  test('open fails fast when the helper is not registered', () async {
    const channel = MethodChannel(SerialBridgeClient.channelName);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'ensureRegistered') return 'requiresApproval';
          return null;
        });
    final client = SerialBridgeClient();
    await expectLater(
      client.open(
        SerialConfig(
          device: '/dev/null',
          baudRate: 9600,
          dataBits: 8,
          parity: SerialParity.none,
          stopBits: 1,
          flowControl: SerialFlowControl.none,
        ),
      ),
      throwsA(isA<SerialBridgeException>()),
    );
  });
}

// --- pty helpers (darwin) ---

/// One long-lived Python process owns the pty pair, because fds cannot cross
/// Process.run boundaries. It prints the slave tty name, then serves commands
/// on stdin: `read <N>` -> hex bytes on stdout, `write <hex>`, `close`.
class _PtyBridge {
  _PtyBridge(this._process) {
    _stdin = _process.stdin;
    _stdout = StreamQueue(
      _process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
  }

  final Process _process;
  late final IOSink _stdin;
  late final StreamQueue<String> _stdout;

  static Future<(_PtyBridge, String)> start() async {
    final process = await Process.start('python3', [
      '-u',
      '-c',
      '''
import os, pty, sys
m, s = pty.openpty()
print("SLAVE:" + os.ttyname(s), flush=True)
print("READY", flush=True)
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    if line == "close":
        os.close(m); os.close(s)
        print("CLOSED", flush=True)
        break
    cmd, _, arg = line.partition(" ")
    if cmd == "read":
        data = os.read(m, int(arg))
        print("HEX:" + data.hex(), flush=True)
    elif cmd == "write":
        os.write(m, bytes.fromhex(arg))
        print("WROTE", flush=True)
''',
    ]);
    final bridge = _PtyBridge(process);
    String? slaveName;
    for (var i = 0; i < 8; i++) {
      final line = await bridge._stdout.next.timeout(
        const Duration(seconds: 5),
      );
      if (line.startsWith('SLAVE:')) {
        slaveName = line.substring(6);
      } else if (line == 'READY') {
        if (slaveName == null) {
          fail('pty bridge never reported its slave name');
        }
        return (bridge, slaveName);
      }
    }
    fail('pty bridge never became ready');
  }

  Future<String> read(int length) async {
    _stdin.writeln('read $length');
    await _stdin.flush();
    final line = await _stdout.next.timeout(const Duration(seconds: 5));
    return line.startsWith('HEX:') ? line.substring(4) : line;
  }

  Future<void> write(List<int> bytes) async {
    _stdin.writeln(
      'write ${bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}',
    );
    await _stdin.flush();
    await _stdout.next.timeout(const Duration(seconds: 5)); // WROTE
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      _stdin.writeln('close');
      await _stdin.flush();
      await _stdout.next.timeout(const Duration(seconds: 5)); // CLOSED
    } on Object {
      // Python may have already exited (or the queue drained); nothing to do.
    }
  }

  var _closed = false;
}

List<int> _hexToBytes(String hex) {
  final normalized = hex.trim();
  return [
    for (var i = 0; i + 1 < normalized.length; i += 2)
      int.parse(normalized.substring(i, i + 2), radix: 16),
  ];
}

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this._support);

  final Directory _support;

  @override
  Future<String?> getApplicationSupportPath() async => _support.path;
}
