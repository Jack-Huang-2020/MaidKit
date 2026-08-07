import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'server_models.dart';
import 'socks5_protocol.dart';

/// Timeout for establishing the connection to the proxy and negotiating the
/// tunnel. Matches the SSH handshake timeout used by dartssh2.
const proxyHandshakeTimeout = Duration(seconds: 15);

/// Raised when the proxy rejects the tunnel or the handshake is malformed.
class ProxyConnectException implements Exception {
  const ProxyConnectException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Negotiates a tunnel through [proxy] to [targetHost]:[targetPort] and
/// returns an [SSHSocket] ready for the SSH handshake.
///
/// The target hostname is sent to the proxy verbatim, so DNS resolution
/// happens at the proxy rather than on this device. This is what allows an
/// IPv4-only network to reach IPv6-only SSH servers through a proxy.
Future<SSHSocket> connectThroughProxy(
  ServerProxy proxy,
  String targetHost,
  int targetPort, {
  Duration timeout = proxyHandshakeTimeout,
}) async {
  if (proxy.type == ServerProxyType.none) {
    throw ArgumentError('connectThroughProxy requires a non-null proxy type.');
  }
  final socket = await Socket.connect(proxy.host, proxy.port, timeout: timeout);
  socket.setOption(SocketOption.tcpNoDelay, true);
  final controller = StreamController<Uint8List>();
  final feed = _ProxySocketFeed(socket, controller);
  try {
    switch (proxy.type) {
      case ServerProxyType.http:
        await _httpConnect(
          socket,
          feed,
          proxy,
          targetHost,
          targetPort,
          timeout,
        );
      case ServerProxyType.socks5:
        await _socks5Connect(
          socket,
          feed,
          proxy,
          targetHost,
          targetPort,
          timeout,
        );
      case ServerProxyType.none:
        throw StateError('unreachable');
    }
  } catch (_) {
    socket.destroy();
    await feed.dispose();
    // Nobody has listened to the controller yet, so `close()` would never
    // deliver its done event and its future would not complete. Just release
    // the socket; the controller is garbage after this call throws.
    unawaited(controller.close());
    rethrow;
  }
  feed.startPump();
  return ProxyTunnelSocket._(socket, controller.stream, feed);
}

/// An [SSHSocket] whose read side is fed by the tunnel negotiation. The raw
/// socket's stream is consumed by a single subscription owned by
/// [_ProxySocketFeed] for the whole connection lifetime; [stream] exposes
/// the negotiated tunnel instead.
class ProxyTunnelSocket implements SSHSocket {
  ProxyTunnelSocket._(this._socket, this._stream, this._feed);

  final Socket _socket;
  final Stream<Uint8List> _stream;
  final _ProxySocketFeed _feed;

  @override
  Stream<Uint8List> get stream => _stream;

  @override
  StreamSink<List<int>> get sink => _socket;

  @override
  Future<void> get done => _socket.done;

  @override
  Future<void> close() async {
    await _feed.dispose();
    await _socket.close();
  }

  @override
  void destroy() {
    _feed.dispose();
    _socket.destroy();
  }

  @override
  Future<void> flush() => _socket.flush();

  @override
  String toString() => _socket.toString();
}

/// Owns the single subscription on the proxy socket.
///
/// During the handshake incoming bytes are buffered and served to the
/// handshake reads. After the tunnel is established ([startPump]) bytes flow
/// straight into the [StreamController] that backs the returned [SSHSocket];
/// any buffered overshoot is replayed first.
class _ProxySocketFeed {
  _ProxySocketFeed(this._socket, this._controller) {
    _subscription = _socket.listen(
      _onData,
      onError: _controller.addError,
      onDone: _onDone,
      cancelOnError: true,
    );
  }

  final Socket _socket;
  final StreamController<Uint8List> _controller;
  final _buffer = BytesBuilder(copy: false);
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
      // No SSH client listens yet, but closing now is harmless and makes a
      // tunnel fail fast if the proxy dies right after the handshake. The
      // future never completes without a listener, so do not await it.
      unawaited(_controller.close());
    }
  }

  void _completeWake() {
    final wake = _wake;
    if (wake != null && !wake.isCompleted) wake.complete();
  }

  /// Reads exactly [count] bytes buffered from the socket, waiting for more
  /// with [timeout] on each chunk.
  Future<Uint8List> read(int count, Duration timeout) async {
    while (_buffer.length < count) {
      if (_closed) {
        throw const ProxyConnectException(
          'The proxy closed the connection during the handshake.',
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

  /// Reads until the HTTP header terminator `\r\n\r\n` and returns everything
  /// including it.
  Future<String> readUntilHeaders(Duration timeout) async {
    final marker = utf8.encode('\r\n\r\n');
    while (_indexOf(_buffer.toBytes(), marker) == null) {
      if (_closed) {
        throw const ProxyConnectException(
          'The proxy closed the connection during the handshake.',
        );
      }
      final wake = _wake = Completer<void>();
      await wake.future.timeout(timeout);
    }
    final bytes = _buffer.takeBytes();
    final end = _indexOf(bytes, marker)! + marker.length;
    final result = utf8.decode(bytes.sublist(0, end), allowMalformed: true);
    if (bytes.length > end) _buffer.add(bytes.sublist(end));
    return result;
  }

  /// Switches from buffering to forwarding. Any bytes buffered beyond the
  /// handshake response are replayed into the tunnel stream.
  void startPump() {
    _pumping = true;
    final leftover = _buffer.takeBytes();
    if (leftover.isNotEmpty) _controller.add(Uint8List.fromList(leftover));
  }

  Future<void> dispose() async {
    await _subscription?.cancel();
    _subscription = null;
  }

  static int? _indexOf(List<int> haystack, List<int> needle) {
    outer:
    for (var i = 0; i + needle.length <= haystack.length; i++) {
      for (var j = 0; j < needle.length; j++) {
        if (haystack[i + j] != needle[j]) continue outer;
      }
      return i;
    }
    return null;
  }
}

Future<void> _httpConnect(
  Socket socket,
  _ProxySocketFeed feed,
  ServerProxy proxy,
  String targetHost,
  int targetPort,
  Duration timeout,
) async {
  final authority = _httpAuthority(targetHost, targetPort);
  final request = StringBuffer()
    ..write('CONNECT $authority HTTP/1.1\r\n')
    ..write('Host: $authority\r\n');
  final username = proxy.username;
  final password = proxy.password;
  if ((username != null && username.isNotEmpty) ||
      (password != null && password.isNotEmpty)) {
    final token = base64Encode(
      utf8.encode('${username ?? ''}:${password ?? ''}'),
    );
    request.write('Proxy-Authorization: Basic $token\r\n');
  }
  request.write('\r\n');
  socket.add(utf8.encode(request.toString()));
  await socket.flush();

  final header = await feed.readUntilHeaders(timeout);
  final statusLine = header.split('\r\n').first;
  final statusMatch = RegExp(
    r'^HTTP/\d(?:\.\d)?\s+(\d{3})',
  ).firstMatch(statusLine);
  final status = statusMatch?.group(1);
  if (status != '200') {
    throw ProxyConnectException(
      'The HTTP proxy rejected the tunnel ($statusLine).',
    );
  }
}

Future<void> _socks5Connect(
  Socket socket,
  _ProxySocketFeed feed,
  ServerProxy proxy,
  String targetHost,
  int targetPort,
  Duration timeout,
) async {
  final username = proxy.username;
  final password = proxy.password;
  final hasCredentials =
      (username != null && username.isNotEmpty) ||
      (password != null && password.isNotEmpty);
  // Offer no-auth and, when configured, username/password authentication
  // (RFC 1929); the proxy picks which it supports.
  socket.add(
    hasCredentials ? const [0x05, 0x02, 0x00, 0x02] : const [0x05, 0x01, 0x00],
  );
  await socket.flush();

  final method = await feed.read(2, timeout);
  if (method[0] != 0x05) {
    throw const ProxyConnectException('The proxy is not a SOCKS5 server.');
  }
  switch (method[1]) {
    case 0x00:
      break;
    case 0x02:
      final userBytes = utf8.encode(username ?? '');
      final passBytes = utf8.encode(password ?? '');
      socket.add(
        Uint8List.fromList([
          0x01,
          userBytes.length,
          ...userBytes,
          passBytes.length,
          ...passBytes,
        ]),
      );
      await socket.flush();
      final auth = await feed.read(2, timeout);
      if (auth[0] != 0x01 || auth[1] != 0x00) {
        throw const ProxyConnectException(
          'The SOCKS5 proxy rejected the supplied credentials.',
        );
      }
    default:
      throw ProxyConnectException(
        'The SOCKS5 proxy requires an unsupported authentication method '
        '(0x${method[1].toRadixString(16)}).',
      );
  }

  final address = encodeSocks5Address(targetHost);
  socket.add(
    Uint8List.fromList([
      0x05,
      0x01,
      0x00,
      address.atyp,
      ...address.bytes,
      ..._port(targetPort),
    ]),
  );
  await socket.flush();

  final header = await feed.read(4, timeout);
  if (header[0] != 0x05) {
    throw const ProxyConnectException(
      'The SOCKS5 proxy sent an invalid response.',
    );
  }
  if (header[1] != 0x00) {
    throw ProxyConnectException(
      'The SOCKS5 proxy could not connect to the target '
      '(${socks5ErrorMessage(header[1])}).',
    );
  }
  // Consume the proxy's bound address so the SSH client never sees it.
  switch (header[3]) {
    case 0x01:
      await feed.read(4 + 2, timeout);
    case 0x03:
      final length = await feed.read(1, timeout);
      await feed.read(length[0] + 2, timeout);
    case 0x04:
      await feed.read(16 + 2, timeout);
    default:
      throw const ProxyConnectException(
        'The SOCKS5 proxy sent an invalid address type.',
      );
  }
}

/// The request target as a single HTTP authority: `host:port` with an IPv6
/// literal wrapped in brackets.
String _httpAuthority(String host, int port) {
  final formattedHost = host.contains(':') ? '[$host]' : host;
  return '$formattedHost:$port';
}

List<int> _port(int port) => [port >> 8, port & 0xff];
