import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maid_kit/theme.dart';
import 'package:material_symbols_icons/symbols.dart';

void main() {
  test('theme renders Material Symbols icons bold (wght 700)', () {
    final light = createMaidKitTheme(Brightness.light);
    final dark = createMaidKitTheme(Brightness.dark);
    expect(light.iconTheme.weight, 700);
    expect(dark.iconTheme.weight, 700);
  });

  testWidgets('rendered icons carry the wght 700 font variation',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: createMaidKitTheme(Brightness.light),
        home: const Scaffold(body: Icon(Symbols.refresh_rounded)),
      ),
    );

    final richText = tester.widget<RichText>(find.byType(RichText));
    final style = richText.text.style;
    expect(style, isNotNull);
    expect(
      style!.fontVariations,
      contains(const FontVariation('wght', 700)),
    );
  });
}
