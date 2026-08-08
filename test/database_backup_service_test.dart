import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:maid_kit/data/local/app_database.dart';
import 'package:maid_kit/servers/cloud_sync_service.dart';
import 'package:maid_kit/servers/database_backup_service.dart';
import 'package:maid_kit/servers/vault_service.dart';

Map<String, dynamic> _payload(List<Map<String, dynamic>> servers) => {
  'version': 3,
  'servers': servers,
  'savedCredentials': <Map<String, dynamic>>[],
  'composeProjectLinks': <Map<String, dynamic>>[],
  'containerCacheEntries': <Map<String, dynamic>>[],
  'deploymentProjects': <Map<String, dynamic>>[],
  'deploymentResources': <Map<String, dynamic>>[],
  'scriptSnippets': <Map<String, dynamic>>[],
  'githubConnections': <Map<String, dynamic>>[],
  'githubRepoPins': <Map<String, dynamic>>[],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (call) async => Directory.systemTemp.path,
      );
  test(
    'decrypts, merges disjoint records, and re-encrypts with passphrase',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'backup_merge_test',
      );
      final database = AppDatabase(filePath: '${directory.path}/vault.sqlite');
      final vault = VaultService(database);
      final backup = DatabaseBackupService(database, vault);
      const password = 'current-vault-passphrase';
      try {
        final localArchive = await vault.encryptPortable(
          jsonEncode(
            _payload([
              {
                'id': 1,
                'syncId': 'local-server',
                'name': 'Local',
                'updatedAt': '2026-08-08T10:00:00Z',
              },
            ]),
          ),
          password,
        );
        final remoteArchive = await vault.encryptPortable(
          jsonEncode(
            _payload([
              {
                'id': 2,
                'syncId': 'remote-server',
                'name': 'Remote',
                'updatedAt': '2026-08-08T10:01:00Z',
              },
            ]),
          ),
          password,
        );

        final result = await backup.compareAndMergeArchives(
          localArchive: localArchive,
          remoteArchive: remoteArchive,
          password: password,
        );

        expect(result.status, CloudSyncArchiveMergeStatus.merged);
        final merged =
            jsonDecode(await vault.decryptPortable(result.archive!, password))
                as Map<String, dynamic>;
        expect((merged['servers'] as List), hasLength(2));
      } finally {
        await database.close();
        await directory.delete(recursive: true);
      }
    },
  );

  test('leaves equal-timestamp edits for the conflict prompt', () async {
    final directory = await Directory.systemTemp.createTemp(
      'backup_conflict_test',
    );
    final database = AppDatabase(filePath: '${directory.path}/vault.sqlite');
    final vault = VaultService(database);
    final backup = DatabaseBackupService(database, vault);
    const password = 'current-vault-passphrase';
    try {
      final localArchive = await vault.encryptPortable(
        jsonEncode(
          _payload([
            {
              'id': 1,
              'syncId': 'same-server',
              'name': 'Local edit',
              'updatedAt': '2026-08-08T10:00:00Z',
            },
          ]),
        ),
        password,
      );
      final remoteArchive = await vault.encryptPortable(
        jsonEncode(
          _payload([
            {
              'id': 1,
              'syncId': 'same-server',
              'name': 'Remote edit',
              'updatedAt': '2026-08-08T10:00:00Z',
            },
          ]),
        ),
        password,
      );

      final result = await backup.compareAndMergeArchives(
        localArchive: localArchive,
        remoteArchive: remoteArchive,
        password: password,
      );

      expect(result.status, CloudSyncArchiveMergeStatus.conflict);
    } finally {
      await database.close();
      await directory.delete(recursive: true);
    }
  });
}
