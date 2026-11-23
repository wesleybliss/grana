import 'package:flutter/material.dart';

import 'package:grana/db/database.dart';
import 'package:grana/l10n/app_localizations.dart';
import 'package:grana/ui/widgets/country_flag.dart';

class ScannerTopBar extends StatelessWidget {
  final String activeSourceCurrency;
  final bool isSourceLocked;
  final bool hasLocationCurrency;
  final bool isFrozen;
  final bool isTorchOn;
  final bool hasTorch;
  final VoidCallback onBack;
  final VoidCallback onPickSourceCurrency;
  final VoidCallback onToggleTorch;
  final VoidCallback onPickGallery;

  const ScannerTopBar({
    super.key,
    required this.activeSourceCurrency,
    required this.isSourceLocked,
    this.hasLocationCurrency = false,
    required this.isFrozen,
    required this.isTorchOn,
    required this.hasTorch,
    required this.onBack,
    required this.onPickSourceCurrency,
    required this.onToggleTorch,
    required this.onPickGallery,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            _GlassCircleButton(
              key: const Key('scanner_back_button'),
              icon: Icons.arrow_back,
              tooltip: MaterialLocalizations.of(context).backButtonTooltip,
              onPressed: onBack,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: _SourceCurrencyChip(
                  currencySymbol: activeSourceCurrency,
                  isLocked: isSourceLocked,
                  hasLocationCurrency: hasLocationCurrency,
                  autoLabel: l10n.autoDetectCurrency,
                  onTap: onPickSourceCurrency,
                ),
              ),
            ),
            const SizedBox(width: 8),
            if (!isFrozen && hasTorch) ...[
              _GlassCircleButton(
                key: const Key('scanner_torch_button'),
                icon: isTorchOn ? Icons.flash_on : Icons.flash_off,
                tooltip: 'Flash',
                onPressed: onToggleTorch,
              ),
              const SizedBox(width: 8),
            ],
            _GlassCircleButton(
              key: const Key('scanner_gallery_button'),
              icon: Icons.photo_library_outlined,
              tooltip: l10n.pickFromGallery,
              onPressed: onPickGallery,
            ),
          ],
        ),
      ),
    );
  }
}

class _GlassCircleButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  const _GlassCircleButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withAlpha(155),
      shape: const CircleBorder(),
      child: IconButton(
        icon: Icon(icon, color: Colors.white, size: 22),
        tooltip: tooltip,
        onPressed: onPressed,
      ),
    );
  }
}

class _SourceCurrencyChip extends StatelessWidget {
  final String currencySymbol;
  final bool isLocked;
  final bool hasLocationCurrency;
  final String autoLabel;
  final VoidCallback onTap;

  const _SourceCurrencyChip({
    required this.currencySymbol,
    required this.isLocked,
    required this.hasLocationCurrency,
    required this.autoLabel,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withAlpha(180),
      shape: StadiumBorder(
        side: BorderSide(
          color: isLocked
              ? const Color(0xFF00E083).withAlpha(200)
              : Colors.white.withAlpha(90),
          width: 1.2,
        ),
      ),
      child: InkWell(
        key: const Key('scanner_source_currency_chip'),
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              buildCurrencyFlag(
                currencySymbol,
                opacity: 1.0,
                style: BuildCurrencyFlagStyle.roundedRectangle,
              ),
              const SizedBox(width: 6),
              Text(
                currencySymbol,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
              if (!isLocked) ...[
                const SizedBox(width: 4),
                Icon(
                  hasLocationCurrency
                      ? Icons.near_me_rounded
                      : Icons.auto_fix_high_rounded,
                  size: 13,
                  color: const Color(0xFF00E083),
                ),
                const SizedBox(width: 2),
                Text(
                  autoLabel,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
              const SizedBox(width: 2),
              const Icon(
                Icons.keyboard_arrow_down_rounded,
                color: Colors.white,
                size: 18,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<void> showSourceCurrencyPickerSheet({
  required BuildContext context,
  required List<Currency> pinnedCurrencies,
  required List<Currency> allCurrencies,
  required String? currentLockedSymbol,
  String? locationCurrencyCode,
  required ValueChanged<String?> onSelect,
}) async {
  final l10n = AppLocalizations.of(context)!;
  String query = '';

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (sheetCtx) {
      return StatefulBuilder(
        builder: (ctx, setModalState) {
          final seen = <String>{};
          final prioritized = <Currency>[];

          // Put location-detected currency at the very top so it's 1 tap away
          if (locationCurrencyCode != null) {
            for (final c in allCurrencies) {
              if (c.symbol == locationCurrencyCode && seen.add(c.symbol)) {
                prioritized.add(c);
                break;
              }
            }
          }
          for (final c in pinnedCurrencies) {
            if (seen.add(c.symbol)) prioritized.add(c);
          }

          final others = allCurrencies
              .where((c) => !seen.contains(c.symbol))
              .toList()
            ..sort((a, b) => a.symbol.compareTo(b.symbol));
          final combined = [...prioritized, ...others];

          final filtered = query.trim().isEmpty
              ? combined
              : combined.where((c) {
                  final q = query.trim().toLowerCase();
                  return c.symbol.toLowerCase().contains(q) ||
                      c.name.toLowerCase().contains(q);
                }).toList();

          final keyboardBottom = MediaQuery.viewInsetsOf(ctx).bottom;

          return Padding(
            padding: EdgeInsets.only(bottom: keyboardBottom),
            child: DraggableScrollableSheet(
              expand: false,
              initialChildSize: 0.7,
              maxChildSize: 0.92,
              minChildSize: 0.45,
              builder: (_, scrollController) {
                return Column(
                  children: [
                    const SizedBox(height: 12),
                    Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.grey.withAlpha(100),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                      child: Text(
                        l10n.sourceCurrency,
                        style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: TextField(
                        key: const Key('scanner_currency_search_field'),
                        decoration: InputDecoration(
                          hintText: l10n.searchByNameOrSymbol,
                          prefixIcon: const Icon(Icons.search),
                          isDense: true,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onChanged: (val) => setModalState(() => query = val),
                      ),
                    ),
                    const SizedBox(height: 8),
                    ListTile(
                      key: const Key('scanner_currency_auto_option'),
                      leading: Icon(
                        locationCurrencyCode != null
                            ? Icons.near_me_rounded
                            : Icons.auto_fix_high_rounded,
                        color: const Color(0xFF00E083),
                      ),
                      title: Text(
                        locationCurrencyCode != null
                            ? '${l10n.autoDetectCurrency} ($locationCurrencyCode)'
                            : l10n.autoDetectCurrency,
                      ),
                      trailing: currentLockedSymbol == null
                          ? const Icon(
                              Icons.check_circle,
                              color: Color(0xFF00E083),
                            )
                          : null,
                      onTap: () {
                        onSelect(null);
                        Navigator.of(sheetCtx).pop();
                      },
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: ListView.builder(
                        controller: scrollController,
                        itemCount: filtered.length,
                        itemBuilder: (_, idx) {
                          final item = filtered[idx];
                          final selected = currentLockedSymbol == item.symbol;
                          return ListTile(
                            leading: buildCurrencyFlag(
                              item.symbol,
                              opacity: 1.0,
                              style: BuildCurrencyFlagStyle.roundedRectangle,
                            ),
                            title: Text(
                              item.symbol,
                              style:
                                  const TextStyle(fontWeight: FontWeight.w600),
                            ),
                            subtitle: Text(item.name),
                            trailing: selected
                                ? const Icon(
                                    Icons.check_circle,
                                    color: Color(0xFF00E083),
                                  )
                                : null,
                            onTap: () {
                              onSelect(item.symbol);
                              Navigator.of(sheetCtx).pop();
                            },
                          );
                        },
                      ),
                    ),
                  ],
                );
              },
            ),
          );
        },
      );
    },
  );
}
