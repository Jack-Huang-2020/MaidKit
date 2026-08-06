import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';

import 'package:maid_kit/data/local/app_database.dart';

import 'vault_service.dart';

/// Creates portable, password-encrypted snapshots of the user-managed data.
///
/// Vault metadata is deliberately excluded: it is tied to the vault on this
/// device. Credentials are decrypted only while the archive is assembled and
/// are encrypted again with the destination vault key during import.
class DatabaseBackupService {
  DatabaseBackupService(this._database, this._vault);

  static const _formatVersion = 3;

  final AppDatabase _database;
  final VaultService _vault;

  Future<String> exportArchive(String password) async {
    return _vault.encryptPortable(await exportPayload(), password);
  }

  /// Produces the clear-text, versioned database payload before it is encrypted
  /// with the vault passphrase. It must never be persisted or sent over the
  /// network without [exportArchive].
  Future<String> exportPayload() async {
    final archive = await _payload();
    archive['createdAt'] = DateTime.now().toUtc().toIso8601String();
    return jsonEncode(archive);
  }

  /// A stable fingerprint of the syncable content. The export timestamp is
  /// excluded so identical database states always produce the same value;
  /// used to skip cloud uploads when nothing changed since the last sync.
  Future<String> contentFingerprint() async {
    final archive = await _payload();
    return sha256.convert(utf8.encode(jsonEncode(archive))).toString();
  }

  Future<Map<String, Object?>> _payload() async {
    final servers = await _database.select(_database.servers).get();
    final credentials = await _database
        .select(_database.savedCredentials)
        .get();
    final serverRecords = <Map<String, dynamic>>[];
    for (final server in servers) {
      final record = server.toJson()
        ..remove('encryptedCredential')
        ..remove('credentialNonce')
        ..remove('encryptedProxyPassword')
        ..remove('proxyPasswordNonce');
      if (server.encryptedCredential != null &&
          server.credentialNonce != null) {
        record['credential'] = await _vault.decrypt(
          EncryptedValue(
            bytes: server.encryptedCredential!,
            nonce: server.credentialNonce!,
          ),
          context: 'server-credential',
        );
      }
      if (server.encryptedProxyPassword != null &&
          server.proxyPasswordNonce != null) {
        record['proxyPassword'] = await _vault.decrypt(
          EncryptedValue(
            bytes: server.encryptedProxyPassword!,
            nonce: server.proxyPasswordNonce!,
          ),
          context: 'server-proxy-password',
        );
      }
      serverRecords.add(record);
    }
    final credentialRecords = <Map<String, dynamic>>[];
    for (final credential in credentials) {
      final record = credential.toJson()
        ..remove('encryptedCredential')
        ..remove('credentialNonce');
      record['credential'] = await _vault.decrypt(
        EncryptedValue(
          bytes: credential.encryptedCredential,
          nonce: credential.credentialNonce,
        ),
        context: 'server-credential',
      );
      credentialRecords.add(record);
    }

    final archive = <String, Object?>{
      'version': _formatVersion,
      'servers': serverRecords,
      'savedCredentials': credentialRecords,
      'composeProjectLinks':
          (await _database.select(_database.composeProjectLinks).get())
              .map((record) => record.toJson())
              .toList(),
      'containerCacheEntries':
          (await _database.select(_database.containerCacheEntries).get())
              .map((record) => record.toJson())
              .toList(),
      'deploymentProjects':
          (await _database.select(_database.deploymentProjects).get())
              .map((record) => record.toJson())
              .toList(),
      'deploymentResources':
          (await _database.select(_database.deploymentResources).get())
              .map((record) => record.toJson())
              .toList(),
      'scriptSnippets': (await _database.select(_database.scriptSnippets).get())
          .map((record) => record.toJson())
          .toList(),
      // GitHub metadata syncs with the vault; access tokens never do. They
      // live in the OS keychain and are re-created by signing in again.
      'githubConnections':
          (await _database.select(_database.gitHubConnections).get())
              .map((record) => record.toJson())
              .toList(),
      'githubRepoPins': (await _database.select(_database.gitHubRepoPins).get())
          .map((record) => record.toJson())
          .toList(),
    };
    return archive;
  }

  /// Replaces the portable database content while retaining this device's
  /// vault metadata and biometric setting.
  Future<void> importArchive(String archive, String password) async {
    final clearText = await _vault.decryptPortable(archive, password);
    await importPayload(clearText);
  }

  /// Replaces the syncable database content after archive decryption.
  Future<void> importPayload(String clearText) async {
    final payload = jsonDecode(clearText);
    if (payload is! Map<String, dynamic> ||
        payload['version'] != _formatVersion) {
      throw const FormatException('Unsupported MaidKit backup.');
    }

    final servers = _records(payload, 'servers');
    final credentials = _records(payload, 'savedCredentials');
    final composeLinks = _records(payload, 'composeProjectLinks');
    final cacheEntries = _records(payload, 'containerCacheEntries');
    final projects = _records(payload, 'deploymentProjects');
    final resources = _records(payload, 'deploymentResources');
    final snippets = _records(payload, 'scriptSnippets');
    // Optional keys: archives written before the GitHub integration carry no
    // GitHub metadata, which imports as an empty connection state. Tokens are
    // never part of an archive, so a synced connection simply needs a new
    // device sign-in.
    final githubConnections = _recordsOrEmpty(payload, 'githubConnections');
    final githubRepoPins = _recordsOrEmpty(payload, 'githubRepoPins');

    await _database.transaction(() async {
      await _database.delete(_database.deploymentResources).go();
      await _database.delete(_database.deploymentProjects).go();
      await _database.delete(_database.containerCacheEntries).go();
      await _database.delete(_database.composeProjectLinks).go();
      await _database.delete(_database.scriptSnippets).go();
      await _database.delete(_database.gitHubRepoPins).go();
      await _database.delete(_database.gitHubConnections).go();
      await _database.delete(_database.servers).go();
      await _database.delete(_database.savedCredentials).go();

      for (final record in credentials) {
        // The archive intentionally excludes these device-specific fields.
        // `SavedCredential.fromJson` cannot be used here because its database
        // representation requires them, even though we replace them below.
        final credential = SavedCredential.fromJson({
          ...record,
          'encryptedCredential': '',
          'credentialNonce': '',
        });
        final clearText = record['credential'];
        if (clearText is! String) {
          throw const FormatException('Invalid saved credential.');
        }
        final encrypted = await _vault.encrypt(
          clearText,
          context: 'server-credential',
        );
        await _database
            .into(_database.savedCredentials)
            .insert(
              SavedCredentialsCompanion(
                id: Value(credential.id),
                name: Value(credential.name),
                credentialType: Value(credential.credentialType),
                encryptedCredential: Value(encrypted.bytes),
                credentialNonce: Value(encrypted.nonce),
                createdAt: Value(credential.createdAt),
                updatedAt: Value(credential.updatedAt),
              ),
            );
      }

      for (final record in servers) {
        // Backups written before the serial-port feature omit the
        // connectionType key; those servers were SSH by definition.
        final server = Server.fromJson({
          ...record,
          'connectionType': record['connectionType'] ?? 'ssh',
        });
        final credential = record['credential'];
        final encrypted = credential is String
            ? await _vault.encrypt(credential, context: 'server-credential')
            : null;
        final proxyPassword = record['proxyPassword'];
        final encryptedProxyPassword = proxyPassword is String
            ? await _vault.encrypt(
                proxyPassword,
                context: 'server-proxy-password',
              )
            : null;
        await _database
            .into(_database.servers)
            .insert(
              ServersCompanion(
                id: Value(server.id),
                name: Value(server.name),
                host: Value(server.host),
                port: Value(server.port),
                username: Value(server.username),
                lastConnectedAt: Value(server.lastConnectedAt),
                syncId: Value(server.syncId),
                createdAt: Value(server.createdAt),
                updatedAt: Value(server.updatedAt),
                deletedAt: Value(server.deletedAt),
                credentialType: Value(server.credentialType),
                encryptedCredential: Value(encrypted?.bytes),
                credentialNonce: Value(encrypted?.nonce),
                credentialId: Value(server.credentialId),
                hostKeyAlgorithm: Value(server.hostKeyAlgorithm),
                hostKeyFingerprint: Value(server.hostKeyFingerprint),
                collectStats: Value(server.collectStats),
                collectSystemInfo: Value(server.collectSystemInfo),
                proxyType: Value(server.proxyType),
                proxyHost: Value(server.proxyHost),
                proxyPort: Value(server.proxyPort),
                proxyUsername: Value(server.proxyUsername),
                encryptedProxyPassword: Value(encryptedProxyPassword?.bytes),
                proxyPasswordNonce: Value(encryptedProxyPassword?.nonce),
                environment: Value(server.environment),
                initialSnippets: Value(server.initialSnippets),
                tags: Value(server.tags),
                connectionType: Value(server.connectionType),
                serialConfig: Value(server.serialConfig),
                sortOrder: Value(server.sortOrder),
              ),
            );
      }
      for (final record in composeLinks) {
        await _database
            .into(_database.composeProjectLinks)
            .insert(ComposeProjectLink.fromJson(record).toCompanion(false));
      }
      for (final record in cacheEntries) {
        await _database
            .into(_database.containerCacheEntries)
            .insert(ContainerCacheEntry.fromJson(record).toCompanion(false));
      }
      for (final record in projects) {
        await _database
            .into(_database.deploymentProjects)
            .insert(DeploymentProject.fromJson(record).toCompanion(false));
      }
      for (final record in resources) {
        await _database
            .into(_database.deploymentResources)
            .insert(DeploymentResource.fromJson(record).toCompanion(false));
      }
      for (final record in snippets) {
        await _database
            .into(_database.scriptSnippets)
            .insert(ScriptSnippet.fromJson(record).toCompanion(false));
      }
      for (final record in githubConnections) {
        await _database
            .into(_database.gitHubConnections)
            .insert(GitHubConnection.fromJson(record).toCompanion(false));
      }
      for (final record in githubRepoPins) {
        await _database
            .into(_database.gitHubRepoPins)
            .insert(GitHubRepoPin.fromJson(record).toCompanion(false));
      }
    });
  }

  List<Map<String, dynamic>> _recordsOrEmpty(
    Map<String, dynamic> payload,
    String key,
  ) {
    final records = payload[key];
    if (records == null) return const [];
    if (records is! List) throw FormatException('Invalid $key in backup.');
    return records.map((record) {
      if (record is! Map) throw FormatException('Invalid $key record.');
      return Map<String, dynamic>.from(record);
    }).toList();
  }

  List<Map<String, dynamic>> _records(
    Map<String, dynamic> payload,
    String key,
  ) {
    final records = payload[key];
    if (records is! List) throw FormatException('Invalid $key in backup.');
    return records.map((record) {
      if (record is! Map) throw FormatException('Invalid $key record.');
      return Map<String, dynamic>.from(record);
    }).toList();
  }
}
