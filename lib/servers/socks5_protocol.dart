import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Timeout for a SOCKS5 client to complete the handshake after connecting.
const socks5HandshakeTimeout = Duration(seconds: 30);

/// Raised when a SOCKS5 handshake fails: a malformed request, an unsupported
/// command or address type, or the client closing early.
class Socks5ProtocolException implements Exception {
  const Socks5ProtocolException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The SOCKS5 CONNECT address. Domain names are sent as-is (ATYP 3) so DNS
/// resolution happens at the proxy; IP literals use the compact binary form.
({int atyp, List<int> bytes}) encodeSocks5Address(String host) {
  final ip = InternetAddress.tryParse(host);
  if (ip != null) {
    return switch (ip.type) {
      InternetAddressType.IPv4 => (atyp: 0x01, bytes: ip.rawAddress),
      InternetAddressType.IPv6 => (atyp: 0x04, bytes: ip.rawAddress),
      _ => (atyp: 0x03, bytes: utf8.encode(host)),
    };
  }
  final bytes = utf8.encode(host);
  if (bytes.length > 255) {
    throw ArgumentError('The target hostname is too long for SOCKS5.');
  }
  return (atyp: 0x03, bytes: [bytes.length, ...bytes]);
}

String socks5ErrorMessage(int code) => switch (code) {
  0x01 => 'general failure',
  0x02 => 'connection not allowed by ruleset',
  0x03 => 'network unreachable',
  0x04 => 'host unreachable',
  0x05 => 'connection refused',
  0x06 => 'TTL expired',
  0x07 => 'command not supported',
  0x08 => 'address type not supported',
  _ => 'unknown error 0x${code.toRadixString(16)}',
};

/// Server-side SOCKS5 (RFC 1928) handshake over a client connection.
///
/// Owns the single subscription on [input]: handshake bytes are buffered and
/// served to the reads. Once [startPump] is called, any overshoot is replayed
/// and subsequent bytes flow straight into [stream] for tunneling.
class Socks5ServerHandshake {
  Socks5ServerHandshake(Stream<List<int>> input, this._output) {
    _subscription = input.listen(
      _onData,
      onError: _output.addError,
      onDone: _onDone,
      cancelOnError: true,
    );
  }

  final IOSink _output;
  final _buffer = BytesBuilder(copy: false);
  final _controller = StreamController<Uint8List>();
  StreamSubscription<List<int>>? _subscription;
  Completer<void>? _wake;
  bool _closed = false;
  bool _pumping = false;

  void _onData(List<int> chunk) {
    if (_pumping) {
      _controller.add(Uint8List.fromList(chunk));
    } else {
      _buffer.add(chunk);
      _completeWake();
    }
  }

  void _onDone() {
    _closed = true;
    _completeWake();
    if (_pumping) {
      _controller.close();
    } else {
      // No tunnel pipes yet; closing now makes a client that drops right
      // after the handshake fail fast. Without a listener the future never
      // completes, so do not await it.
      unawaited(_controller.close());
    }
  }

  void _completeWake() {
    final wake = _wake;
    if (wake != null && !wake.isCompleted) wake.complete();
  }

  Future<Uint8List> _read(int count, Duration timeout) async {
    while (_buffer.length < count) {
      if (_closed) {
        throw const Socks5ProtocolException(
          'The client closed the connection during the SOCKS5 handshake.',
        );
      }
      final wake = _wake = Completer<void>();
      await wake.future.timeout(timeout);
    }
    final bytes = _buffer.takeBytes();
    final result = Uint8List.fromList(bytes.sublist(0, count));
    if (bytes.length > count) _buffer.add(bytes.sublist(count));
    return result;
  }

  /// Negotiates the greeting and CONNECT request, replying with no-auth and
  /// success, and returns the client-chosen destination.
  Future<({String host, int port})> negotiate({
    Duration timeout = socks5HandshakeTimeout,
  }) async {
    // Greeting: VER, NMETHODS, METHODS.
    final greeting = await _read(2, timeout);
    if (greeting[0] != 0x05) {
      throw const Socks5ProtocolException('The client is not speaking SOCKS5.');
    }
    final methodCount = greeting[1];
    if (methodCount == 0) {
      throw const Socks5ProtocolException(
        'The client offered no auth methods.',
      );
    }
    final methods = await _read(methodCount, timeout);
    if (!methods.contains(0x00)) {
      // No acceptable methods: 0xFF.
      await _reply(const [0x05, 0xff], timeout);
      throw const Socks5ProtocolException(
        'The client requires unsupported authentication.',
      );
    }
    await _reply(const [0x05, 0x00], timeout); // no-auth

    // CONNECT request: VER, CMD, RSV, ATYP, address, port.
    final header = await _read(4, timeout);
    if (header[0] != 0x05 || header[2] != 0x00) {
      throw const Socks5ProtocolException('Malformed SOCKS5 request header.');
    }
    if (header[1] != 0x01) {
      // BIND (0x02) and UDP ASSOCIATE (0x03) cannot be carried over an SSH
      // TCP tunnel: UDP would need a relay running on the SSH server.
      await _reply(_failureReply(0x07), timeout);
      throw Socks5ProtocolException(
        'Unsupported SOCKS5 command 0x${header[1].toRadixString(16)}.',
      );
    }

    final atyp = header[3];
    final String host;
    final int port;
    switch (atyp) {
      case 0x01: // IPv4
      case 0x04: // IPv6
        final address = await _read(atyp == 0x01 ? 4 : 16, timeout);
        final portBytes = await _read(2, timeout);
        host = InternetAddress.fromRawAddress(
          address,
          type: atyp == 0x01
              ? InternetAddressType.IPv4
              : InternetAddressType.IPv6,
        ).address;
        port = _decodePort(portBytes);
      case 0x03: // domain name
        final length = (await _read(1, timeout))[0];
        if (length == 0) {
          throw const Socks5ProtocolException('Empty SOCKS5 domain name.');
        }
        final name = await _read(length, timeout);
        final portBytes = await _read(2, timeout);
        host = utf8.decode(name);
        port = _decodePort(portBytes);
      default:
        await _reply(_failureReply(0x08), timeout);
        throw Socks5ProtocolException(
          'Unsupported SOCKS5 address type 0x${atyp.toRadixString(16)}.',
        );
    }

    await _reply(_successReply(), timeout);
    return (host: host, port: port);
  }

  Future<void> _reply(List<int> bytes, Duration timeout) async {
    _output.add(bytes);
    await _output.flush().timeout(timeout);
  }

  /// Switches from buffering to forwarding. Any bytes buffered beyond the
  /// handshake are replayed into [stream].
  void startPump() {
    _pumping = true;
    final leftover = _buffer.takeBytes();
    if (leftover.isNotEmpty) _controller.add(Uint8List.fromList(leftover));
  }

  /// The client's tunnel traffic after the handshake.
  Stream<Uint8List> get stream => _controller.stream;

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
  }
}

int _decodePort(List<int> bytes) => (bytes[0] << 8) | bytes[1];

/// A success reply with an unspecified bound address (0.0.0.0:0), which
/// clients accept per RFC 1928.
List<int> _successReply() => const [0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0];

List<int> _failureReply(int code) => [0x05, code, 0x00, 0x01, 0, 0, 0, 0, 0, 0];
