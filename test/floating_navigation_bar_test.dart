import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maid_kit/shared/presentation/floating_navigation_bar.dart';
import 'package:material_symbols_icons/symbols.dart';

Widget _host(FloatingNavigationBar bar) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox.expand(
        child: bar,
      ),
    ),
  );
}

void main() {
  testWidgets('shows all destinations and highlights the selected one',
      (tester) async {
    await tester.pumpWidget(
      _host(
        FloatingNavigationBar(
          selectedIndex: 1,
          onDestinationSelected: (_) {},
          destinations: const [
            NavigationDestination(
              icon: Icon(Symbols.dns_rounded),
              label: 'Servers',
            ),
            NavigationDestination(
              icon: Icon(Symbols.code_rounded),
              label: 'Snippets',
            ),
            NavigationDestination(
              icon: Icon(Symbols.settings_rounded),
              label: 'Settings',
            ),
          ],
        ),
      ),
    );

    expect(find.text('Servers'), findsNothing); // unselected: icon only
    expect(find.text('Snippets'), findsOneWidget); // selected: label shown
    expect(find.text('Settings'), findsNothing);
    expect(find.byIcon(Symbols.dns_rounded), findsOneWidget);
    expect(find.byIcon(Symbols.code_rounded), findsOneWidget);
  });

  testWidgets('reports destination taps', (tester) async {
    var selected = 0;
    await tester.pumpWidget(
      _host(
        FloatingNavigationBar(
          selectedIndex: selected,
          onDestinationSelected: (index) => selected = index,
          destinations: const [
            NavigationDestination(
              icon: Icon(Symbols.dns_rounded),
              label: 'Servers',
            ),
            NavigationDestination(
              icon: Icon(Symbols.code_rounded),
              label: 'Snippets',
            ),
          ],
        ),
      ),
    );

    await tester.tap(find.byIcon(Symbols.code_rounded));
    expect(selected, 1);
  });
}
