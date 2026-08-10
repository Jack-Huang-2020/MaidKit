import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:maid_kit/servers/app_theme_preferences.dart';
import 'package:maid_kit/servers/server_providers.dart';

void main() {
  test('saves the app accent seed color', () async {
    final settings = InMemoryAppThemeSettings();
    final container = ProviderContainer(
      overrides: [appThemeSettingsProvider.overrideWithValue(settings)],
    );
    addTearDown(container.dispose);
    const color = Color(0xFF2563EB);

    await container.read(appSeedColorProvider.notifier).setSeedColor(color);

    expect(settings.seedColor, color);
    expect(container.read(appSeedColorProvider), color);
  });

  test('toggles the wallpaper color flag', () async {
    final settings = InMemoryAppThemeSettings();
    final container = ProviderContainer(
      overrides: [appThemeSettingsProvider.overrideWithValue(settings)],
    );
    addTearDown(container.dispose);

    // Defaults to enabled to keep the previous Android behavior.
    expect(container.read(wallpaperColorEnabledProvider), isTrue);

    await container
        .read(wallpaperColorEnabledProvider.notifier)
        .setEnabled(false);

    expect(settings.wallpaperColorEnabled, isFalse);
    expect(container.read(wallpaperColorEnabledProvider), isFalse);
  });
}
