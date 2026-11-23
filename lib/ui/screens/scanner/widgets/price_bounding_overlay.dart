import 'package:flutter/material.dart';

import 'package:grana/domain/models/scanned_price.dart';

class PriceBoundingOverlay extends StatelessWidget {
  final List<ScannedPriceItem> items;
  final String? selectedItemId;
  final bool showCenterReticle;
  final bool dimReticle;
  final ValueChanged<String> onSelectItem;

  const PriceBoundingOverlay({
    super.key,
    required this.items,
    required this.selectedItemId,
    required this.showCenterReticle,
    this.dimReticle = false,
    required this.onSelectItem,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxW = constraints.maxWidth;
        final maxH = constraints.maxHeight;

        return Stack(
          children: [
            if (showCenterReticle)
              IgnorePointer(
                child: Center(
                  child: AnimatedOpacity(
                    duration: const Duration(milliseconds: 220),
                    opacity: dimReticle ? 0.25 : 1.0,
                    child: Container(
                      width: (maxW * 0.68).clamp(160.0, 300.0),
                      height: 100,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: Colors.white.withAlpha(120),
                          width: 1.5,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            for (final item in items)
              if (item.boundingBox != null) _buildBoxPill(item, maxW, maxH),
          ],
        );
      },
    );
  }

  Widget _buildBoxPill(ScannedPriceItem item, double maxW, double maxH) {
    final box = item.boundingBox!;
    final isSelected = item.id == selectedItemId;

    final rawW = box.width * maxW;
    final rawH = box.height * maxH;
    final width = (rawW + 8.0).clamp(48.0, maxW);
    final height = (rawH + 6.0).clamp(28.0, maxH);

    final centerX = box.centerX * maxW;
    final centerY = box.centerY * maxH;
    final left = (centerX - width / 2.0).clamp(2.0, (maxW - width - 2.0).clamp(2.0, maxW));
    final top = (centerY - height / 2.0).clamp(2.0, (maxH - height - 2.0).clamp(2.0, maxH));

    const accentGreen = Color(0xFF00E083);

    return AnimatedPositioned(
      key: ValueKey('price_box_${item.id}'),
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      left: left,
      top: top,
      width: width,
      height: height,
      child: GestureDetector(
        onTap: () => onSelectItem(item.id),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          decoration: BoxDecoration(
            color: isSelected
                ? accentGreen.withAlpha(55)
                : Colors.black.withAlpha(75),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isSelected ? accentGreen : Colors.white.withAlpha(180),
              width: isSelected ? 2.2 : 1.2,
            ),
          ),
        ),
      ),
    );
  }
}
