import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

/// Owns vault database files after they have been selected by the user.
///
/// Keeping a private copy in the application support directory makes vaults
/// work the same way on desktop and mobile, where picker paths are not
/// durable, without placing app data in the user's Documents folder.
class VaultFileStorage {
  static const _directoryName = 'vaults';
  static const _extension = '.maidkit';
  final Uuid _uuid = const Uuid();

  Future<String> createVaultPath({String? name}) async {
    final directory = await _vaultDirectory();
    final stem = _safeStem(fileName(name ?? 'MaidKit vault'));
    return '${directory.path}/$stem-${_uuid.v4()}$_extension';
  }

  Future<String> importVault(String sourcePath) async {
    final source = File(sourcePath);
    if (!await source.exists()) {
      throw FileSystemException('Vault file was not found.', sourcePath);
    }
    final directory = await _vaultDirectory();
    if (isInDirectory(source.path, directory.path)) return source.path;

    final name = _safeStem(fileName(source.path));
    final target = File(
      '${directory.path}/$name-${source.path.hashCode.abs()}$_extension',
    );
    if (!await target.exists()) await source.copy(target.path);
    return target.path;
  }

  Future<void> deleteVault(String path) async {
    final directory = await _vaultDirectory();
    if (!isInDirectory(path, directory.path)) {
      throw FileSystemException(
        'Only managed vault files can be deleted.',
        path,
      );
    }
    final file = File(path);
    if (await file.exists()) await file.delete();
  }

  Future<Directory> _vaultDirectory() async {
    final support = await getApplicationSupportDirectory();
    return Directory('${support.path}/$_directoryName').create(recursive: true);
  }

  /// The final path segment, tolerating both '/' and '\' separators.
  ///
  /// Managed vault paths are built with '/' while path_provider and
  /// FilePicker may report native '\' paths on Windows, so splitting on
  /// [Platform.pathSeparator] alone would return the whole path there.
  String fileName(String path) => path.split(RegExp(r'[/\\]')).last;

  /// Whether [path] points inside [directory], tolerant of '/' and '\'
  /// separators and of a trailing separator on [directory].
  bool isInDirectory(String path, String directory) {
    final normalizedPath = path.replaceAll('\\', '/');
    final normalizedDirectory = directory
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'/+$'), '');
    return normalizedPath == normalizedDirectory ||
        normalizedPath.startsWith('$normalizedDirectory/');
  }

  String _safeStem(String value) {
    final withoutExtension = value.replaceFirst(RegExp(r'\.[^.]*$'), '');
    final sanitized = withoutExtension.replaceAll(
      RegExp(r'[^a-zA-Z0-9 _-]'),
      '_',
    );
    return sanitized.trim().isEmpty ? 'Vault' : sanitized.trim();
  }
}
