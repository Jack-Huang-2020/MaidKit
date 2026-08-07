import 'package:shared_preferences/shared_preferences.dart';

/// Persisted preference controlling whether the local machine appears as a
/// server card in the dashboard.
abstract interface class LocalMachineSettings {
  bool get localMachineEnabled;

  Future<void> saveLocalMachineEnabled(bool value);
}

class LocalMachinePreferences implements LocalMachineSettings {
  LocalMachinePreferences(this._preferences, this.localMachineEnabled);

  static const _localMachineEnabledKey = 'local_machine_enabled';

  final SharedPreferencesAsync _preferences;
  @override
  final bool localMachineEnabled;

  static Future<LocalMachinePreferences> load({
    SharedPreferencesAsync? preferences,
  }) async {
    final store = preferences ?? SharedPreferencesAsync();
    return LocalMachinePreferences(
      store,
      await store.getBool(_localMachineEnabledKey) ?? false,
    );
  }

  @override
  Future<void> saveLocalMachineEnabled(bool value) =>
      _preferences.setBool(_localMachineEnabledKey, value);
}

class InMemoryLocalMachineSettings implements LocalMachineSettings {
  InMemoryLocalMachineSettings([this.localMachineEnabled = false]);

  @override
  bool localMachineEnabled;

  @override
  Future<void> saveLocalMachineEnabled(bool value) async {
    localMachineEnabled = value;
  }
}
