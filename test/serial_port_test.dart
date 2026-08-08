import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:maid_kit/servers/serial_port_client.dart';
import 'package:maid_kit/servers/server_models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(SerialPortClient.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final codec = const StandardMethodCodec();
  final calls = <MethodCall>[];

  tearDown(() {
    calls.clear();
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('lists devices returned by the native app', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      expect(call.method, 'listDevices');
      return ['/dev/cu.usbmodem123'];
    });

    final devices = await SerialPortClient().listDevices();

    expect(devices, ['/dev/cu.usbmodem123']);
  });

  test('opens, writes, and closes a native serial session', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'open':
          return 42;
        case 'write':
        case 'close':
          return null;
        default:
          fail('Unexpected method ${call.method}');
      }
    });

    final session = await SerialPortClient().open(
      const SerialConfig(
        device: '/dev/cu.usbmodem123',
        baudRate: 115200,
        dataBits: 8,
        parity: SerialParity.none,
        stopBits: 1,
        flowControl: SerialFlowControl.none,
      ),
    );
    session.write([0x68, 0x69]);
    await Future<void>.delayed(Duration.zero);
    await session.close();

    expect(calls.map((call) => call.method), ['open', 'write', 'close']);
    final openArguments = calls.first.arguments as Map<Object?, Object?>;
    expect(openArguments['device'], '/dev/cu.usbmodem123');
    final writeArguments = calls[1].arguments as Map<Object?, Object?>;
    expect(writeArguments['sessionId'], 42);
    expect(writeArguments['data'], isA<Uint8List>());
  });

  test('delivers native bytes and completion to a session', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'open') return 7;
      return null;
    });
    final client = SerialPortClient();
    final session = await client.open(
      const SerialConfig(
        device: '/dev/cu.usbmodem123',
        baudRate: 9600,
        dataBits: 8,
        parity: SerialParity.none,
        stopBits: 1,
        flowControl: SerialFlowControl.none,
      ),
    );
    final received = session.bytes.first;

    await messenger.handlePlatformMessage(
      SerialPortClient.channelName,
      codec.encodeMethodCall(
        MethodCall('data', {
          'sessionId': 7,
          'data': Uint8List.fromList([0x6f, 0x6b]),
        }),
      ),
      (_) {},
    );
    expect(await received, [0x6f, 0x6b]);
    final done = session.done;
    await messenger.handlePlatformMessage(
      SerialPortClient.channelName,
      codec.encodeMethodCall(const MethodCall('done', {'sessionId': 7})),
      (_) {},
    );
    await done;
  });

  test('reports native open errors as serial exceptions', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      throw PlatformException(
        code: 'serial_error',
        message: 'Cannot open /dev/cu.missing: No such file or directory',
      );
    });

    await expectLater(
      SerialPortClient().open(
        const SerialConfig(
          device: '/dev/cu.missing',
          baudRate: 115200,
          dataBits: 8,
          parity: SerialParity.none,
          stopBits: 1,
          flowControl: SerialFlowControl.none,
        ),
      ),
      throwsA(
        isA<SerialPortException>().having(
          (error) => error.message,
          'message',
          contains('Cannot open /dev/cu.missing'),
        ),
      ),
    );
  });
}
