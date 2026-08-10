import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

abstract interface class AppThemeSettings {
  Color get seedColor;

  /// Whether the wallpaper-extracted dynamic color (Monet) is used on
  /// Android. When enabled the manual accent color picker is disabled.
  bool get wallpaperColorEnabled;

  Future<void> saveSeedColor(Color color);

  Future<void> saveWallpaperColorEnabled(bool enabled);
}

class AppThemePreferences implements AppThemeSettings {
  AppThemePreferences(
    this._preferences,
    this.seedColor, {
    this.wallpaperColorEnabled = true,
  });

  static const _seedColorKey = 'app_theme_seed_color';
  static const _wallpaperColorKey = 'app_theme_wallpaper_color';
  static const _defaultSeedColor = Color(0xFF0F766E);

  final SharedPreferencesAsync _preferences;
  @override
  final Color seedColor;
  @override
  final bool wallpaperColorEnabled;

  static Future<AppThemePreferences> load({
    SharedPreferencesAsync? preferences,
  }) async {
    final store = preferences ?? SharedPreferencesAsync();
    return AppThemePreferences(
      store,
      Color(await store.getInt(_seedColorKey) ?? _defaultSeedColor.toARGB32()),
      wallpaperColorEnabled:
          await store.getBool(_wallpaperColorKey) ?? true,
    );
  }

  @override
  Future<void> saveSeedColor(Color color) async {
    await _preferences.setInt(_seedColorKey, color.toARGB32());
  }

  @override
  Future<void> saveWallpaperColorEnabled(bool enabled) async {
    await _preferences.setBool(_wallpaperColorKey, enabled);
  }
}

class InMemoryAppThemeSettings implements AppThemeSettings {
  InMemoryAppThemeSettings({
    this.seedColor = const Color(0xFF0F766E),
    this.wallpaperColorEnabled = true,
  });

  @override
  Color seedColor;
  @override
  bool wallpaperColorEnabled;

  @override
  Future<void> saveSeedColor(Color color) async => seedColor = color;

  @override
  Future<void> saveWallpaperColorEnabled(bool enabled) async =>
      wallpaperColorEnabled = enabled;
}
