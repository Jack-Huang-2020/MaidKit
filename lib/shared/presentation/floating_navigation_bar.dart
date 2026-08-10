import 'package:flutter/material.dart';

/// Total vertical space the floating bar occupies (bottom margin + pill
/// height + padding). Hosts use this as bottom inset so content scrolls clear
/// of the bar when it floats over the body (extendBody).
const floatingNavigationBarInset = 80.0;

/// A floating, pill-shaped bottom navigation bar inspired by the PiliPlus
/// client. It floats above the bottom edge inside a rounded container with a
/// subtle shadow, and the selected destination gets a smooth highlight
/// capsule that expands to reveal its label (icon-only when unselected).
///
/// Designed for narrow layouts where the [NavigationRail] does not fit.
class FloatingNavigationBar extends StatelessWidget {
  const FloatingNavigationBar({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.destinations,
    this.bottomPadding = 12,
    this.animationDuration = const Duration(milliseconds: 220),
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<NavigationDestination> destinations;
  final double bottomPadding;
  final Duration animationDuration;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    // heightFactor: 1 keeps the bar at its content height. Without it the
    // root Align expands to fill the whole Scaffold bottomNavigationBar slot
    // (Scaffold constrains it loosely), squeezing the body to zero height and
    // leaving a blank page with only the pill visible.
    return SafeArea(
      top: false,
      minimum: EdgeInsets.only(bottom: bottomPadding),
      child: Align(
        alignment: Alignment.bottomCenter,
        heightFactor: 1,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainer,
            borderRadius: BorderRadius.circular(32),
            border: Border.all(
              color: colorScheme.outlineVariant.withValues(alpha: 0.5),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.1),
                blurRadius: 16,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.all(4),
            // Scale down on very narrow viewports instead of overflowing.
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < destinations.length; i++)
                    _FloatingDestination(
                      index: i,
                      selected: i == selectedIndex,
                      destination: destinations[i],
                      duration: animationDuration,
                      onTap: () => onDestinationSelected(i),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FloatingDestination extends StatefulWidget {
  const _FloatingDestination({
    required this.index,
    required this.selected,
    required this.destination,
    required this.duration,
    required this.onTap,
  });

  final int index;
  final bool selected;
  final NavigationDestination destination;
  final Duration duration;
  final VoidCallback onTap;

  @override
  State<_FloatingDestination> createState() => _FloatingDestinationState();
}

class _FloatingDestinationState extends State<_FloatingDestination> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final selected = widget.selected;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: widget.duration,
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          color: selected
              ? colorScheme.secondaryContainer
              : _hovered
              ? colorScheme.onSurface.withValues(alpha: 0.06)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(28),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(28),
          onTap: widget.onTap,
          child: AnimatedSize(
            duration: widget.duration,
            curve: Curves.easeOutCubic,
            alignment: Alignment.center,
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: selected ? 16 : 10,
                vertical: 8,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconTheme.merge(
                    data: const IconThemeData(size: 22),
                    child: selected
                        ? widget.destination.selectedIcon ??
                              widget.destination.icon
                        : widget.destination.icon,
                  ),
                  if (selected)
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: Text(
                        widget.destination.label,
                        style: theme.textTheme.labelMedium,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
