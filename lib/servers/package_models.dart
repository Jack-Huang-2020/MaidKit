enum PackageManager { apt, dnf, yum, pacman, zypper, apk, xbps, brew }

extension PackageManagerX on PackageManager {
  String get label => switch (this) {
    PackageManager.apt => 'APT',
    PackageManager.dnf => 'DNF',
    PackageManager.yum => 'YUM',
    PackageManager.pacman => 'Pacman',
    PackageManager.zypper => 'Zypper',
    PackageManager.apk => 'APK',
    PackageManager.xbps => 'XBPS',
    PackageManager.brew => 'Homebrew',
  };

  /// Homebrew is designed to manage user-owned installations without sudo.
  bool get requiresElevation => this != PackageManager.brew;
}

enum PackageAction { refresh, upgrade, install, remove }

extension PackageActionX on PackageAction {
  String get label => switch (this) {
    PackageAction.refresh => 'Refresh indexes',
    PackageAction.upgrade => 'Upgrade packages',
    PackageAction.install => 'Install',
    PackageAction.remove => 'Remove',
  };

  bool get isDestructive => this == PackageAction.remove;
}

class PackageManagerStatus {
  const PackageManagerStatus({
    required this.available,
    required this.manager,
    required this.installedPackageCount,
    required this.outdatedPackages,
  });

  final List<PackageManager> available;
  final PackageManager? manager;
  final int? installedPackageCount;
  final List<String> outdatedPackages;

  PackageManager? get preferred =>
      manager ?? (available.isEmpty ? null : available.first);
}

class PackageSearchResult {
  const PackageSearchResult({
    required this.name,
    this.version,
    this.description,
    this.installed = false,
  });

  final String name;
  final String? version;
  final String? description;
  final bool installed;
}
