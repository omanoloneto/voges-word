import 'package:flutter/material.dart';

/// Faixas do ícone, do azul claro (topo) ao escuro (base).
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

  /// Contorno claro para o ícone não sumir sobre o azul da faixa.
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
