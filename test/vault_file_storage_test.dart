import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:maid_kit/servers/vault_file_storage.dart';

void main() {
  final storage = VaultFileStorage();

  group('VaultFileStorage.createVaultPath', () {
    test('stores new vaults under application support', () async {
      final support = await Directory.systemTemp.createTemp(
        'maidkit-vault-storage-',
      );
      final previous = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _FakePathProvider(support);
      addTearDown(() async {
        PathProviderPlatform.instance = previous;
        await support.delete(recursive: true);
      });

      final path = await storage.createVaultPath(name: 'Primary Vault');

      expect(
        storage.isInDirectory(
          path,
          '${support.path}${Platform.pathSeparator}vaults',
        ),
        isTrue,
      );
      expect(storage.fileName(path), startsWith('Primary Vault-'));
      expect(path, endsWith('.maidkit'));
    });
  });

  group('VaultFileStorage.fileName', () {
    test('returns the basename for native Windows separators', () {
      expect(
        storage.fileName(r'C:\Users\Me\Documents\vaults\a.maidkit'),
        'a.maidkit',
      );
    });

    test('returns the basename for forward-slash managed paths', () {
      expect(
        storage.fileName('C:/Users/Me/Documents/vaults/a.maidkit'),
        'a.maidkit',
      );
    });

    test('returns the path itself when it has no separators', () {
      expect(storage.fileName('a.maidkit'), 'a.maidkit');
    });
  });

  group('VaultFileStorage.isInDirectory', () {
    test('recognizes a managed vault when separators differ', () {
      // path_provider reports Application Support with '\' on Windows while
      // managed vault paths are built with '/'; both must count as in-directory.
      expect(
        storage.isInDirectory(
          'C:/Users/Me/Application Support/vaults/a.maidkit',
          r'C:\Users\Me\Application Support',
        ),
        isTrue,
      );
    });

    test('recognizes a managed vault with matching separators', () {
      expect(
        storage.isInDirectory(
          r'C:\Users\Me\Application Support\vaults\a.maidkit',
          r'C:\Users\Me\Application Support',
        ),
        isTrue,
      );
      expect(
        storage.isInDirectory(
          'C:/Users/Me/Application Support/vaults/a.maidkit',
          'C:/Users/Me/Application Support',
        ),
        isTrue,
      );
    });

    test('tolerates a trailing separator on the directory', () {
      expect(
        storage.isInDirectory(
          'C:/Users/Me/Application Support/vaults/a.maidkit',
          r'C:\Users\Me\Application Support\',
        ),
        isTrue,
      );
    });

    test('rejects files outside the directory', () {
      expect(
        storage.isInDirectory(
          'C:/Users/Me/Other/a.maidkit',
          'C:/Users/Me/Application Support',
        ),
        isFalse,
      );
    });

    test('rejects sibling paths that merely share a prefix', () {
      expect(
        storage.isInDirectory(
          'C:/Users/Me/Application SupportVaults/a.maidkit',
          'C:/Users/Me/Application Support',
        ),
        isFalse,
      );
    });
  });
}

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this._support);

  final Directory _support;

  @override
  Future<String?> getApplicationSupportPath() async => _support.path;
}
