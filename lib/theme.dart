import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

/// Registered font families from `assets/fonts`.
abstract final class MaidKitFonts {
  static const sans = 'IBM Plex Sans';
  static const mono = 'IBM Plex Mono';
}

/// The application-wide Material theme. Keep feature widgets dependent on this
/// shared foundation instead of creating local colour schemes or chrome.
///
/// Pass a [colorScheme] (e.g. the Android 12+ wallpaper Monet palette from
/// `DynamicColorBuilder`) to follow the system dynamic color; otherwise the
/// theme falls back to a palette derived from [seedColor].
ThemeData createMaidKitTheme(
  Brightness brightness, {
  Color? seedColor,
  ColorScheme? colorScheme,
}) {
  final resolvedScheme = colorScheme ??
      ColorScheme.fromSeed(
        seedColor: seedColor ?? const Color(0xFF0F766E),
        brightness: brightness,
      );

  return ThemeData(
    useMaterial3: true,
    colorScheme: resolvedScheme,
    brightness: brightness,
    fontFamily: MaidKitFonts.sans,
    appBarTheme: const AppBarTheme(centerTitle: false),
    navigationRailTheme: const NavigationRailThemeData(
      groupAlignment: -1,
      labelType: NavigationRailLabelType.all,
    ),
    inputDecorationTheme: InputDecorationThemeData(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.macOS: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
        TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
      },
    ),
  );
}
