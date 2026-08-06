import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maid_kit/servers/cloud_sync_service.dart';

const _sessionKey = 'maidkit_solar_network_oauth_session';

class _MemoryStorage extends FlutterSecureStorage {
  final Map<String, String> values = {};

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async => values[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    values.remove(key);
  }
}

class _CannedAdapter implements HttpClientAdapter {
  _CannedAdapter(this.handle);

  final Future<ResponseBody> Function(RequestOptions options) handle;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) => handle(options);

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Object body, int status) => ResponseBody.fromString(
  jsonEncode(body),
  status,
  headers: {
    Headers.contentTypeHeader: [Headers.jsonContentType],
  },
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // Stub the native OIDC browser flow: echo the state back in a callback
    // URL so the PKCE state check inside the service passes.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter_web_auth_2'), (
          call,
        ) async {
          if (call.method != 'authenticate') return null;
          final arguments = Map<String, dynamic>.from(call.arguments as Map);
          final url = Uri.parse(arguments['url'] as String);
          final state = url.queryParameters['state']!;
          return 'maidkit://oauth/callback?code=test-code&state=$state';
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_web_auth_2'),
          null,
        );
  });

  test('re-signs in when the stored session is rejected with 401', () async {
    final storage = _MemoryStorage();
    // A session that is not yet expired (no refresh is attempted) but whose
    // access token the server rejects: the stale-session failure mode.
    storage.values[_sessionKey] = jsonEncode({
      'access_token': 'stale-token',
      'refresh_token': 'stale-refresh',
      'expires_at': DateTime.now()
          .add(const Duration(days: 1))
          .toUtc()
          .toIso8601String(),
    });
    var workspaceCalls = 0;
    var tokenExchanges = 0;
    final dio = Dio()
      ..httpClientAdapter = _CannedAdapter((options) async {
        switch (options.uri.path) {
          case '/.well-known/openid-configuration':
            return _json({
              'authorization_endpoint': 'https://id.solian.app/authorize',
              'token_endpoint': 'https://id.solian.app/token',
            }, 200);
          case '/valve/workspaces':
            workspaceCalls++;
            if (workspaceCalls == 1) {
              return _json({'error': 'unauthorized'}, 401);
            }
            return _json([
              {'id': 'workspace-1', 'slug': 'test', 'name': 'Test workspace'},
            ], 200);
          case '/token':
            tokenExchanges++;
            return _json({
              'access_token': 'fresh-token',
              'expires_in': 3600,
            }, 200);
          default:
            return _json({}, 404);
        }
      });

    final service = CloudSyncService(
      vaultId: 'test-vault',
      secureStorage: storage,
      dio: dio,
    );

    final workspaces = await service.signInAndListWorkspaces();

    expect(workspaces.single.id, 'workspace-1');
    expect(workspaces.single.name, 'Test workspace');
    expect(
      tokenExchanges,
      1,
      reason: 'a fresh authorization must follow the rejected session',
    );
    expect(
      storage.values[_sessionKey],
      contains('fresh-token'),
      reason: 'the fresh session replaces the stale one',
    );
  });

  test('signs in directly when no session is stored', () async {
    final storage = _MemoryStorage();
    var tokenExchanges = 0;
    final dio = Dio()
      ..httpClientAdapter = _CannedAdapter((options) async {
        switch (options.uri.path) {
          case '/.well-known/openid-configuration':
            return _json({
              'authorization_endpoint': 'https://id.solian.app/authorize',
              'token_endpoint': 'https://id.solian.app/token',
            }, 200);
          case '/valve/workspaces':
            return _json([
              {'id': 'workspace-2', 'slug': 'two', 'name': 'Second'},
            ], 200);
          case '/token':
            tokenExchanges++;
            return _json({
              'access_token': 'fresh-token',
              'expires_in': 3600,
            }, 200);
          default:
            return _json({}, 404);
        }
      });

    final service = CloudSyncService(
      vaultId: 'test-vault',
      secureStorage: storage,
      dio: dio,
    );

    final workspaces = await service.signInAndListWorkspaces();

    expect(workspaces.single.id, 'workspace-2');
    expect(tokenExchanges, 1);
  });

  test('surfaces a non-401 failure as CloudSyncException', () async {
    final storage = _MemoryStorage();
    final dio = Dio()
      ..httpClientAdapter = _CannedAdapter((options) async {
        switch (options.uri.path) {
          case '/.well-known/openid-configuration':
            return _json({
              'authorization_endpoint': 'https://id.solian.app/authorize',
              'token_endpoint': 'https://id.solian.app/token',
            }, 200);
          case '/valve/workspaces':
            return _json({'error': 'server error'}, 500);
          case '/token':
            return _json({
              'access_token': 'fresh-token',
              'expires_in': 3600,
            }, 200);
          default:
            return _json({}, 404);
        }
      });

    final service = CloudSyncService(
      vaultId: 'test-vault',
      secureStorage: storage,
      dio: dio,
    );
    storage.values[_sessionKey] = jsonEncode({
      'access_token': 'stale-token',
      'expires_at': DateTime.now()
          .add(const Duration(days: 1))
          .toUtc()
          .toIso8601String(),
    });

    await expectLater(
      service.signInAndListWorkspaces(),
      throwsA(
        isA<CloudSyncException>().having(
          (error) => error.toString(),
          'message',
          contains('server error'),
        ),
      ),
    );
  });

  test('loads the current account from the Stargate route', () async {
    final storage = _MemoryStorage();
    final requestedPaths = <String>[];
    final dio = Dio()
      ..httpClientAdapter = _CannedAdapter((options) async {
        requestedPaths.add(options.uri.path);
        switch (options.uri.path) {
          case '/stargate/accounts/me':
            return _json({
              'name': 'littlesheep',
              'nick': 'Little Sheep',
              'profile': {
                'picture': {'id': 'pic-1'},
              },
            }, 200);
          default:
            return _json({}, 404);
        }
      });
    // A session that is not yet expired so no refresh or re-auth is attempted.
    storage.values[_sessionKey] = jsonEncode({
      'access_token': 'valid-token',
      'expires_at': DateTime.now()
          .add(const Duration(days: 1))
          .toUtc()
          .toIso8601String(),
    });

    final service = CloudSyncService(
      vaultId: 'test-vault',
      secureStorage: storage,
      dio: dio,
    );

    final user = await service.currentUser();

    expect(user?.name, 'Little Sheep');
    expect(requestedPaths, ['/stargate/accounts/me']);
  });
}
