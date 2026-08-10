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

  testWidgets('does not squeeze the scaffold body', (tester) async {
    // Regression: the bar used to expand to the full bottomNavigationBar slot
    // height (Align without heightFactor), leaving the body at zero height.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: const Center(child: Text('body content')),
          bottomNavigationBar: FloatingNavigationBar(
            selectedIndex: 0,
            onDestinationSelected: (_) {},
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.dns_outlined),
                label: 'Servers',
              ),
              NavigationDestination(
                icon: Icon(Icons.code_outlined),
                label: 'Snippets',
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('body content'), findsOneWidget);
    expect(tester.getSize(find.text('body content')).height, greaterThan(0));
    expect(
      tester.getSize(find.byType(FloatingNavigationBar)).height,
      lessThan(200), // pill height, not full screen
    );
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
