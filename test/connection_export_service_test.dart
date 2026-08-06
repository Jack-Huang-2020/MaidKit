import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:maid_kit/data/local/app_database.dart';
import 'package:maid_kit/servers/connection_export_service.dart';
import 'package:maid_kit/servers/server_models.dart';
import 'package:maid_kit/servers/server_repository.dart';
import 'package:maid_kit/servers/vault_service.dart';

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

/// drift_flutter resolves its native database directory through
/// path_provider; point it at the system temp directory in tests.
void _mockPathProvider() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, (call) async {
        return Directory.systemTemp.path;
      });
}

void main() {
  _mockPathProvider();

  group('ConnectionExportService', () {
    late AppDatabase database;
    late VaultService vault;
    late ServerRepository repository;
    late ConnectionExportService service;

    setUp(() async {
      final directory = Directory.systemTemp.createTempSync(
        'connection_export_test',
      );
      final storage = _MemoryStorage();
      database = AppDatabase(filePath: '${directory.path}/test.sqlite');
      vault = VaultService(database, secureStorage: storage);
      await vault.create('vault-password');
      repository = ServerRepository(database, vault);
      service = ConnectionExportService(database, vault);
    });

    tearDown(() => database.close());

    Future<Server> insertPasswordServer() => repository.create(
      ServerDraft(
        name: 'prod-db',
        host: '10.0.0.1',
        port: 2222,
        username: 'root',
        credential: ServerCredential.password('hunter2'),
        credentialName: 'prod-db-cred',
        proxy: const ServerProxy(
          type: ServerProxyType.http,
          host: 'proxy.local',
          port: 8080,
          username: 'proxy-user',
          password: 'proxy-pass',
        ),
        environment: const {'KUBECONFIG': '/etc/kubernetes/admin.conf'},
        tags: const ['prod', 'eu-west'],
      ),
    );

    test(
      'redacted JSON omits credentials, proxy password, and environment',
      () async {
        await insertPasswordServer();

        final document =
            jsonDecode(await service.exportJson()) as Map<String, dynamic>;

        expect(document['format'], ConnectionExportService.formatName);
        expect(document['version'], ConnectionExportService.formatVersion);
        expect(document['secrets'], isNull);

        final server =
            (document['servers'] as List).single as Map<String, dynamic>;
        expect(server['name'], 'prod-db');
        expect(server['host'], '10.0.0.1');
        expect(server['port'], 2222);
        expect(server['username'], 'root');
        expect(server['authType'], CredentialType.password.name);
        expect(server['tags'], ['prod', 'eu-west']);
        expect(server['connectionType'], ServerConnectionType.ssh.name);
        expect(server.containsKey('credential'), isFalse);
        expect(server.containsKey('environment'), isFalse);

        final proxy = server['proxy'] as Map<String, dynamic>;
        expect(proxy['type'], ServerProxyType.http.name);
        expect(proxy['host'], 'proxy.local');
        expect(proxy['port'], 8080);
        expect(proxy['username'], 'proxy-user');
        expect(proxy.containsKey('password'), isFalse);

        final credential =
            (document['savedCredentials'] as List).single
                as Map<String, dynamic>;
        expect(credential['name'], 'prod-db-cred');
        expect(credential['authType'], CredentialType.password.name);
        expect(credential.containsKey('credential'), isFalse);
      },
    );

    test(
      'serial servers keep their serial settings in redacted JSON',
      () async {
        await repository.create(
          ServerDraft(
            name: 'router',
            host: '',
            port: 22,
            username: '',
            credential: ServerCredential.password('unused'),
            connectionType: ServerConnectionType.serial,
            serialConfig: const SerialConfig(device: '/dev/tty.usbserial'),
            tags: const ['hardware'],
          ),
        );

        final document =
            jsonDecode(await service.exportJson()) as Map<String, dynamic>;
        final server =
            (document['servers'] as List).single as Map<String, dynamic>;
        expect(server['connectionType'], ServerConnectionType.serial.name);
        expect(server['serial'], {
          'device': '/dev/tty.usbserial',
          'baudRate': 115200,
          'dataBits': 8,
          'parity': 'none',
          'stopBits': 1,
          'flowControl': 'none',
        });
      },
    );

    test('protected JSON encrypts secrets keyed by server position', () async {
      await insertPasswordServer();

      final document =
          jsonDecode(await service.exportJson(passphrase: 'export-pass'))
              as Map<String, dynamic>;

      final secrets =
          jsonDecode(
                await vault.decryptPortable(
                  document['secrets'] as String,
                  'export-pass',
                ),
              )
              as Map<String, dynamic>;

      final serverSecret =
          (secrets['servers'] as List).single as Map<String, dynamic>;
      expect(serverSecret['index'], 0);
      expect(serverSecret['credential'], {
        'type': CredentialType.password.name,
        'password': 'hunter2',
        'privateKey': null,
        'keyPassphrase': null,
      });
      expect(serverSecret['proxyPassword'], 'proxy-pass');
      expect(serverSecret['environment'], {
        'KUBECONFIG': '/etc/kubernetes/admin.conf',
      });

      final credentialSecret =
          (secrets['savedCredentials'] as List).single as Map<String, dynamic>;
      expect(credentialSecret['index'], 0);
      expect(
        credentialSecret['credential'],
        containsPair('password', 'hunter2'),
      );
    });

    test('private key credentials survive the protected export', () async {
      await repository.create(
        ServerDraft(
          name: 'git-deploy',
          host: 'git.internal',
          port: 22,
          username: 'deploy',
          credential: const ServerCredential.privateKey(
            privateKey:
                '-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----\n',
            keyPassphrase: 'key-pass',
          ),
          credentialName: 'git-deploy-key',
        ),
      );

      final document =
          jsonDecode(await service.exportJson(passphrase: 'export-pass'))
              as Map<String, dynamic>;
      final secrets =
          jsonDecode(
                await vault.decryptPortable(
                  document['secrets'] as String,
                  'export-pass',
                ),
              )
              as Map<String, dynamic>;
      final serverSecret =
          (secrets['servers'] as List).single as Map<String, dynamic>;

      expect(serverSecret['credential'], {
        'type': CredentialType.privateKey.name,
        'password': null,
        'privateKey': contains('BEGIN OPENSSH PRIVATE KEY'),
        'keyPassphrase': 'key-pass',
      });
    });

    test('CSV exports the redacted columns with proper quoting', () async {
      await repository.create(
        ServerDraft(
          name: 'prod, "east"',
          host: '10.0.0.2',
          port: 22,
          username: 'admin',
          credential: ServerCredential.password('hunter2'),
          tags: const ['a,1', 'b'],
        ),
      );

      final csv = await service.exportCsv();

      expect(csv, startsWith(ConnectionExportService.csvHeader.join(',')));
      final lines = csv.trim().split('\n');
      expect(lines, hasLength(2));
      expect(
        lines[1],
        '"prod, ""east""",10.0.0.2,22,admin,password,"a\\,1,b",ssh',
      );
    });

    test('soft-deleted servers are excluded', () async {
      final server = await insertPasswordServer();
      await repository.delete(server);

      final document =
          jsonDecode(await service.exportJson()) as Map<String, dynamic>;
      expect(document['servers'], isEmpty);
      expect(
        await service.exportCsv(),
        '${ConnectionExportService.csvHeader.join(',')}\n',
      );
    });
  });
}
