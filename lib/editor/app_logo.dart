import 'package:flutter/material.dart';

/// The icon's bands, from light blue (top) to dark (bottom).
const logoBands = [
  Color(0xFF6BA9F3),
  Color(0xFF5290E8),
  Color(0xFF4079DA),
  Color(0xFF3464C6),
  Color(0xFF2B51AF),
];

class AppLogo extends StatelessWidget {
  const AppLogo({this.size = 24, this.outlined = false, super.key});

  final double size;

  /// Light outline so the icon does not vanish against the blue ribbon.
  final bool outlined;

  @override
  Widget build(BuildContext context) {
    final logo = ClipRRect(
      borderRadius: BorderRadius.circular(size * 0.24),
      child: SizedBox.square(
        dimension: size,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Column(
              children: [
                for (final band in logoBands)
                  Expanded(child: ColoredBox(color: band)),
              ],
            ),
            Center(
              child: Text(
                'W',
                textScaler: TextScaler.noScaling,
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  fontSize: size * 0.64,
                  height: 1,
                ),
              ),
            ),
          ],
        ),
      ),
    );
    return Semantics(
      label: 'Voges Word',
      child: outlined
          ? DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(size * 0.24),
                border: Border.all(color: const Color(0xB3FFFFFF)),
              ),
              child: logo,
            )
          : logo,
    );
  }
}
