import 'package:shared_preferences/shared_preferences.dart';

/// Persists the last interactive command used for each container.
///
/// Commands are local UI history, not credentials or container state.
class ContainerCommandPreferences {
  ContainerCommandPreferences(this._preferences);

  static const _keyPrefix = 'container_last_command_';

  final SharedPreferencesAsync _preferences;

  static Future<ContainerCommandPreferences> load({
    SharedPreferencesAsync? preferences,
  }) async =>
      ContainerCommandPreferences(preferences ?? SharedPreferencesAsync());

  Future<String?> commandFor({
    required int serverId,
    required String containerId,
  }) => _preferences.getString(_key(serverId, containerId));

  Future<void> saveCommand({
    required int serverId,
    required String containerId,
    required String command,
  }) async {
    final value = command.trim();
    if (value.isEmpty) {
      await _preferences.remove(_key(serverId, containerId));
    } else {
      await _preferences.setString(_key(serverId, containerId), value);
    }
  }

  String _key(int serverId, String containerId) =>
      '$_keyPrefix$serverId:$containerId';
}
