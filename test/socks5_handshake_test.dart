import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:maid_kit/servers/socks5_protocol.dart';

/// Verifies the server-side SOCKS5 (RFC 1928) handshake MaidKit runs on a
/// local listener before tunneling traffic over SSH. In-memory streams keep
/// the protocol parsing deterministic.
void main() {
  group('Socks5ServerHandshake', () {
    test('negotiates a domain CONNECT and replays overshoot', () async {
      final input = StreamController<List<int>>();
      final output = _RecordingSink();
      final handshake = Socks5ServerHandshake(input.stream, output);

      final negotiation = handshake.negotiate(
        timeout: const Duration(seconds: 2),
      );
      input.add([0x05, 0x01, 0x00]); // greeting: no-auth offered
      input.add([
        0x05, 0x01, 0x00, 0x03, // VER, CONNECT, RSV, ATYP=domain
        11, ...utf8.encode('example.com'), 0x01, 0xbb, // example.com:443
        0xde, 0xad, 0xbe, 0xef, // payload sent with the request
      ]);
      final destination = await negotiation;

      expect(destination.host, 'example.com');
      expect(destination.port, 443);
      expect(output.chunks, [
        [0x05, 0x00], // no-auth
        [0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0], // success
      ]);

      final traffic = <List<int>>[];
      final subscription = handshake.stream.listen(traffic.add);
      handshake.startPump();
      input.add([0xca, 0xfe]); // payload sent after the handshake
      await pumpEventQueue();
      expect(traffic, [
        [0xde, 0xad, 0xbe, 0xef],
        [0xca, 0xfe],
      ]);

      await subscription.cancel();
      await input.close();
      await handshake.dispose();
    });

    test('negotiates an IPv4 CONNECT', () async {
      final input = StreamController<List<int>>();
      final output = _RecordingSink();
      final handshake = Socks5ServerHandshake(input.stream, output);

      final negotiation = handshake.negotiate(
        timeout: const Duration(seconds: 2),
      );
      input.add([0x05, 0x01, 0x00]);
      input.add([0x05, 0x01, 0x00, 0x01, 93, 184, 216, 34, 0x00, 0x50]);
      final destination = await negotiation;

      expect(destination.host, '93.184.216.34');
      expect(destination.port, 80);

      await input.close();
      await handshake.dispose();
    });

    test('negotiates an IPv6 CONNECT', () async {
      final input = StreamController<List<int>>();
      final output = _RecordingSink();
      final handshake = Socks5ServerHandshake(input.stream, output);

      final negotiation = handshake.negotiate(
        timeout: const Duration(seconds: 2),
      );
      input.add([0x05, 0x01, 0x00]);
      input.add([
        0x05,
        0x01,
        0x00,
        0x04,
        0x20,
        0x01,
        0x0d,
        0xb8,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        1,
        0x01,
        0xbb,
      ]);
      final destination = await negotiation;

      expect(destination.host, '2001:db8::1');
      expect(destination.port, 443);

      await input.close();
      await handshake.dispose();
    });

    test('reads a handshake delivered byte by byte', () async {
      final input = StreamController<List<int>>();
      final output = _RecordingSink();
      final handshake = Socks5ServerHandshake(input.stream, output);

      final negotiation = handshake.negotiate(
        timeout: const Duration(seconds: 2),
      );
      for (final byte in [
        0x05, 0x01, 0x00, // greeting
        0x05, 0x01, 0x00, 0x01, // CONNECT, IPv4
        93, 184, 216, 34, 0x00, 0x50,
      ]) {
        input.add([byte]);
      }
      final destination = await negotiation;

      expect(destination.host, '93.184.216.34');
      expect(destination.port, 80);

      await input.close();
      await handshake.dispose();
    });

    test('rejects UDP ASSOCIATE as command not supported', () async {
      final input = StreamController<List<int>>();
      final output = _RecordingSink();
      final handshake = Socks5ServerHandshake(input.stream, output);

      final negotiation = handshake.negotiate(
        timeout: const Duration(seconds: 2),
      );
      input.add([0x05, 0x01, 0x00]);
      input.add([0x05, 0x03, 0x00, 0x01, 127, 0, 0, 1, 0x1f, 0x90]);
      await expectLater(negotiation, throwsA(isA<Socks5ProtocolException>()));
      expect(output.chunks.last, [0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);

      await input.close();
      await handshake.dispose();
    });

    test('rejects clients that do not offer no-auth', () async {
      final input = StreamController<List<int>>();
      final output = _RecordingSink();
      final handshake = Socks5ServerHandshake(input.stream, output);

      final negotiation = handshake.negotiate(
        timeout: const Duration(seconds: 2),
      );
      input.add([0x05, 0x01, 0x02]); // only username/password
      await expectLater(negotiation, throwsA(isA<Socks5ProtocolException>()));
      expect(output.chunks.last, [0x05, 0xff]);

      await input.close();
      await handshake.dispose();
    });

    test('fails when the client closes mid-handshake', () async {
      final input = StreamController<List<int>>();
      final output = _RecordingSink();
      final handshake = Socks5ServerHandshake(input.stream, output);

      final negotiation = handshake.negotiate(
        timeout: const Duration(seconds: 2),
      );
      input.add([0x05, 0x01]);
      await input.close();
      await expectLater(negotiation, throwsA(isA<Socks5ProtocolException>()));

      await handshake.dispose();
    });

    test('fails on a non-SOCKS5 version byte', () async {
      final input = StreamController<List<int>>();
      final output = _RecordingSink();
      final handshake = Socks5ServerHandshake(input.stream, output);

      final negotiation = handshake.negotiate(
        timeout: const Duration(seconds: 2),
      );
      input.add([0x04, 0x01, 0x00]); // SOCKS4 greeting
      await expectLater(negotiation, throwsA(isA<Socks5ProtocolException>()));

      await input.close();
      await handshake.dispose();
    });

    test('serves a real SOCKS5 client over loopback sockets', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final accepted = server.first.then((socket) async {
        final handshake = Socks5ServerHandshake(socket, socket);
        try {
          final destination = await handshake.negotiate(
            timeout: const Duration(seconds: 2),
          );
          return (
            socket: socket,
            handshake: handshake,
            destination: destination,
          );
        } catch (_) {
          await socket.close();
          rethrow;
        }
      });

      final client = await Socket.connect(
        InternetAddress.loopbackIPv4,
        server.port,
      );
      addTearDown(client.destroy);
      client.add([0x05, 0x01, 0x00]); // greeting: no-auth
      client.add([
        0x05, 0x01, 0x00, 0x03, // CONNECT, domain
        9, ...utf8.encode('localhost'), 0x1f, 0x90,
      ]);
      final result = await accepted;
      expect(result.destination.host, 'localhost');
      expect(result.destination.port, 8080);

      // The client sees the no-auth selection and the success reply.
      final response = <int>[];
      await for (final chunk in client.timeout(const Duration(seconds: 2))) {
        response.addAll(chunk);
        if (response.length >= 12) break;
      }
      expect(response, [0x05, 0x00, 0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);

      await result.handshake.dispose();
      await result.socket.close();
      await client.close();
    });
  });
}

/// Records everything written to it so tests can assert the exact reply bytes.
class _RecordingSink implements IOSink {
  final List<List<int>> chunks = <List<int>>[];
  Encoding _encoding = utf8;

  @override
  void add(List<int> data) => chunks.add(List<int>.from(data));

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      add(chunk);
    }
  }

  @override
  Future<void> flush() async {}

  @override
  Future<void> get done => Future<void>.value();

  @override
  Future<void> close() async {}

  @override
  Encoding get encoding => _encoding;

  @override
  set encoding(Encoding value) => _encoding = value;

  @override
  void write(Object? object) => add(utf8.encode(object.toString()));

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      write(objects.join(separator));

  @override
  void writeCharCode(int charCode) => add([charCode]);

  @override
  void writeln([Object? object = '']) {
    write(object);
    add(const [0x0a]);
  }
}
