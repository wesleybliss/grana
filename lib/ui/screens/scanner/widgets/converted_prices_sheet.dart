import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'package:grana/config/feature_flags.dart';
import 'package:grana/db/database.dart';
import 'package:grana/domain/di/providers/scanner/scanner_provider.dart';
import 'package:grana/domain/models/scanned_price.dart';
import 'package:grana/l10n/app_localizations.dart';
import 'package:grana/ui/widgets/country_flag.dart';
import 'package:grana/utils/currency_locales.dart';
import 'package:grana/utils/currency_utils.dart';

class ConvertedPricesSheet extends StatelessWidget {
  final ScannerState scannerState;
  final String activeSourceCurrency;
  final List<Currency> sortedCurrencies;
  final List<Currency> allCurrencies;
  final int roundingDecimals;
  final bool showFlags;
  final bool enableLiveCameraConversion;
  final bool isCapturing;
  final VoidCallback onPickSourceCurrency;
  final VoidCallback onCaptureFreeze;
  final VoidCallback onResumeLive;
  final ValueChanged<String> onSelectItem;
  final ValueChanged<String> onToggleThousandsShorthand;
  final void Function(String sourceCurrency, double exactAmount)
      onUseInConverter;

  const ConvertedPricesSheet({
    super.key,
    required this.scannerState,
    required this.activeSourceCurrency,
    required this.sortedCurrencies,
    required this.allCurrencies,
    required this.roundingDecimals,
    required this.showFlags,
    this.enableLiveCameraConversion = FeatureFlags.enableLiveCameraConversion,
    this.isCapturing = false,
    required this.onPickSourceCurrency,
    required this.onCaptureFreeze,
    required this.onResumeLive,
    required this.onSelectItem,
    required this.onToggleThousandsShorthand,
    required this.onUseInConverter,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final state = scannerState;
    final items = state.scanResult.items;
    final selectedItem = state.selectedItem;
    final isStillViewfinder = !enableLiveCameraConversion && !state.isFrozen;

    final convertedMap = selectedItem == null
        ? const <String, double>{}
        : convertFromAnyCurrency(
            sourceSymbol: activeSourceCurrency,
            amount: selectedItem.normalizedAmount,
            targetCurrencies: sortedCurrencies,
            allCurrencies: allCurrencies,
            roundingDecimals: roundingDecimals,
          );

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withAlpha(250),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withAlpha(80),
            blurRadius: 16,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildPrimaryActionRow(l10n, theme, state),
              const SizedBox(height: 8),
              Expanded(
                child: _buildBodyContent(
                  l10n: l10n,
                  theme: theme,
                  state: state,
                  items: items,
                  selectedItem: selectedItem,
                  convertedMap: convertedMap,
                ),
              ),
              const SizedBox(height: 8),
              if (isStillViewfinder)
                FilledButton.icon(
                  key: const Key('scanner_capture_button'),
                  onPressed: isCapturing ? null : onCaptureFreeze,
                  icon: isCapturing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.camera_alt_outlined),
                  label: Text(l10n.capturePhoto),
                )
              else
                FilledButton.icon(
                  key: const Key('scanner_use_in_converter_button'),
                  onPressed: selectedItem == null
                      ? null
                      : () => onUseInConverter(
                            activeSourceCurrency,
                            selectedItem.normalizedAmount,
                          ),
                  icon: const Icon(Icons.calculate_outlined),
                  label: Text(l10n.useInConverter),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPrimaryActionRow(
    AppLocalizations l10n,
    ThemeData theme,
    ScannerState state,
  ) {
    return Row(
      children: [
        _buildSourceCurrencyButton(theme),
        const Spacer(),
        if (state.isFrozen)
          OutlinedButton.icon(
            key: const Key('scanner_resume_live_button'),
            onPressed: onResumeLive,
            icon: Icon(
              enableLiveCameraConversion
                  ? Icons.videocam_outlined
                  : Icons.camera_alt_outlined,
              size: 18,
            ),
            label: Text(
              enableLiveCameraConversion ? l10n.scanAgain : l10n.retakePhoto,
            ),
            style: OutlinedButton.styleFrom(
              visualDensity: VisualDensity.compact,
            ),
          )
        else if (enableLiveCameraConversion)
          FilledButton.tonalIcon(
            key: const Key('scanner_freeze_button'),
            onPressed: isCapturing ? null : onCaptureFreeze,
            icon: const Icon(Icons.camera_enhance_outlined, size: 18),
            label: Text(l10n.captureAndAnalyze),
            style: FilledButton.styleFrom(
              visualDensity: VisualDensity.compact,
            ),
          ),
      ],
    );
  }

  Widget _buildSourceCurrencyButton(ThemeData theme) {
    final isLocked = scannerState.lockedSourceCurrency != null;
    return Material(
      color: theme.colorScheme.surfaceContainerHighest.withAlpha(180),
      shape: StadiumBorder(
        side: BorderSide(
          color: isLocked
              ? theme.colorScheme.primary
              : theme.colorScheme.outlineVariant,
          width: 1.2,
        ),
      ),
      child: InkWell(
        key: const Key('scanner_sheet_source_currency_button'),
        customBorder: const StadiumBorder(),
        onTap: onPickSourceCurrency,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (showFlags) ...[
                buildCurrencyFlag(
                  activeSourceCurrency,
                  opacity: 1.0,
                  style: BuildCurrencyFlagStyle.roundedRectangle,
                ),
                const SizedBox(width: 6),
              ],
              Text(
                activeSourceCurrency,
                style: theme.textTheme.labelLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 2),
              Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBodyContent({
    required AppLocalizations l10n,
    required ThemeData theme,
    required ScannerState state,
    required List<ScannedPriceItem> items,
    required ScannedPriceItem? selectedItem,
    required Map<String, double> convertedMap,
  }) {
    if (state.isAnalyzingStill) {
      return Center(
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2.2),
            ),
            const SizedBox(width: 12),
            Text(l10n.analyzingMenuWithAi),
          ],
        ),
      );
    }

    if (selectedItem == null) {
      final emptyMessage = state.isFrozen
          ? l10n.noPricesFoundInPhoto
          : (enableLiveCameraConversion
              ? l10n.pointCameraAtPrice
              : l10n.pointCameraAndCapture);
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            emptyMessage,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSelectedPriceHeader(l10n, theme, selectedItem),
        if (items.length > 1) ...[
          const SizedBox(height: 6),
          SizedBox(
            height: 34,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: items.length,
              separatorBuilder: (_, _) => const SizedBox(width: 6),
              itemBuilder: (_, idx) {
                final item = items[idx];
                final isSelected = item.id == selectedItem.id;
                return ChoiceChip(
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  label: Text(
                    _formatAmount(activeSourceCurrency, item.normalizedAmount),
                  ),
                  selected: isSelected,
                  onSelected: (_) => onSelectItem(item.id),
                );
              },
            ),
          ),
        ],
        const SizedBox(height: 6),
        Expanded(
          child: _buildConversionsList(theme, convertedMap),
        ),
      ],
    );
  }

  Widget _buildSelectedPriceHeader(
    AppLocalizations l10n,
    ThemeData theme,
    ScannedPriceItem selectedItem,
  ) {
    return Row(
      children: [
        Expanded(
          child: Text(
            '${_formatAmount(activeSourceCurrency, selectedItem.normalizedAmount)} $activeSourceCurrency',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
              fontFamily: 'BricolageGrotesque',
            ),
          ),
        ),
        if (selectedItem.canToggleThousandsShorthand ||
            selectedItem.isShorthandMultiplied)
          FilterChip(
            key: const Key('scanner_shorthand_toggle'),
            visualDensity: VisualDensity.compact,
            label: Text(l10n.thousandsShorthandToggle),
            selected: selectedItem.isShorthandMultiplied,
            onSelected: (_) => onToggleThousandsShorthand(selectedItem.id),
          ),
      ],
    );
  }

  Widget _buildConversionsList(
    ThemeData theme,
    Map<String, double> convertedMap,
  ) {
    final targets = sortedCurrencies
        .where((c) => c.symbol != activeSourceCurrency)
        .toList();
    final displayList = targets.isNotEmpty ? targets : sortedCurrencies;

    return ListView.separated(
      itemCount: displayList.length,
      separatorBuilder: (_, _) => Divider(
        height: 8,
        color: theme.colorScheme.outlineVariant.withAlpha(80),
      ),
      itemBuilder: (_, idx) {
        final currency = displayList[idx];
        final value = convertedMap[currency.symbol] ?? 0.0;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              if (showFlags) ...[
                buildCurrencyFlag(
                  currency.symbol,
                  opacity: 0.9,
                  style: BuildCurrencyFlagStyle.roundedRectangle,
                ),
                const SizedBox(width: 8),
              ],
              Text(
                currency.symbol,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _formatAmount(currency.symbol, value),
                  textAlign: TextAlign.end,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  String _formatAmount(String symbol, double value) {
    final maxDigits = (value != 0 && value.abs() < 0.01)
        ? roundingDecimals.clamp(2, 4)
        : roundingDecimals.clamp(0, 2);
    final rounded = double.parse(value.toStringAsFixed(maxDigits));
    final hasDecimals = (rounded - rounded.truncateToDouble()).abs() > 1e-6;
    final digits = hasDecimals ? maxDigits : 0;
    return NumberFormat.currency(
      locale: currencyLocales[symbol] ?? 'en_US',
      symbol: '',
      decimalDigits: digits,
    ).format(rounded).trim();
  }
}
