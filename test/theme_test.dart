import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maid_kit/theme.dart';
import 'package:material_symbols_icons/symbols.dart';

void main() {
  test('theme keeps Material Symbols icons at the default weight', () {
    final light = createMaidKitTheme(Brightness.light);
    final dark = createMaidKitTheme(Brightness.dark);
    // No explicit weight: icons render at the standard 400 weight, matching
    // the PiliPlus-style bottom navigation icons.
    expect(light.iconTheme.weight, isNull);
    expect(dark.iconTheme.weight, isNull);
  });

  testWidgets('renders icons without an explicit weight variation',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: createMaidKitTheme(Brightness.light),
        home: const Scaffold(body: Icon(Symbols.refresh_rounded)),
      ),
    );

    expect(find.byIcon(Symbols.refresh_rounded), findsOneWidget);
    final richText = tester.widget<RichText>(find.byType(RichText));
    final style = richText.text.style;
    expect(
      style?.fontVariations?.any(
            (v) => v.axis == 'wght' && v.value == 700,
          ) ??
          false,
      isFalse,
    );
  });

  test('switch theme resolves Material 3 Expressive check/cross thumb icons',
      () {
    final light = createMaidKitTheme(Brightness.light);
    expect(light.switchTheme?.thumbIcon, isNotNull);
    final dark = createMaidKitTheme(Brightness.dark);
    expect(dark.switchTheme?.thumbIcon, isNotNull);

    // The thumb icon is painted by the Switch's CustomPainter, so assert on
    // the resolved icons: check when on, cross when off.
    final thumbIcon = light.switchTheme!.thumbIcon!;
    final onIcon = thumbIcon.resolve({WidgetState.selected});
    final offIcon = thumbIcon.resolve(const <WidgetState>{});
    expect(onIcon?.icon, Icons.check_rounded);
    expect(offIcon?.icon, Icons.close_rounded);
  });
}
