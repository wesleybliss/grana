import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:spot_di/spot_di.dart';

import 'package:grana/config/feature_flags.dart';
import 'package:grana/domain/di/providers/currencies/currencies_provider.dart';
import 'package:grana/domain/di/providers/currencies/sorted_currencies_provider.dart';
import 'package:grana/domain/io/services/i_price_scanner_service.dart';
import 'package:grana/domain/models/scanned_price.dart';
import 'package:grana/utils/currency_utils.dart';
import 'package:grana/utils/logger.dart';
import 'package:grana/utils/price_text_parser.dart';

@immutable
class ScannerState {
  final ScannerCapabilities capabilities;
  final bool isFrozen;
  final String? frozenImagePath;
  final bool isAnalyzingStill;
  final bool isDownloadingModel;
  final String? lockedSourceCurrency;
  final String? locationCurrencyCode;
  final String? locationCountryCode;
  final ScanAnalysisResult scanResult;
  final String? selectedItemId;
  final bool isAskingAgent;
  final AgentQueryResult? agentResponse;
  final String? errorMessage;

  const ScannerState({
    this.capabilities = const ScannerCapabilities(
      isSupported: true,
      activeTier: AiScannerTier.onDeviceOcr,
      llmStatus: ModelAvailabilityStatus.unavailable,
    ),
    this.isFrozen = false,
    this.frozenImagePath,
    this.isAnalyzingStill = false,
    this.isDownloadingModel = false,
    this.lockedSourceCurrency,
    this.locationCurrencyCode,
    this.locationCountryCode,
    this.scanResult = ScanAnalysisResult.empty,
    this.selectedItemId,
    this.isAskingAgent = false,
    this.agentResponse,
    this.errorMessage,
  });

  String effectiveSourceCurrency(List<String> selectedCurrencies) {
    if (lockedSourceCurrency != null && lockedSourceCurrency!.isNotEmpty) {
      return lockedSourceCurrency!;
    }
    final selected = selectedItem;
    if (selected?.detectedCurrencyCode != null &&
        selected!.detectedCurrencyCode!.isNotEmpty) {
      return selected.detectedCurrencyCode!;
    }
    if (scanResult.inferredCurrencyCode != null &&
        scanResult.inferredCurrencyCode!.isNotEmpty) {
      return scanResult.inferredCurrencyCode!;
    }
    if (locationCurrencyCode != null && locationCurrencyCode!.isNotEmpty) {
      return locationCurrencyCode!;
    }
    return selectedCurrencies.isNotEmpty ? selectedCurrencies.first : 'USD';
  }

  ScannedPriceItem? get selectedItem {
    if (scanResult.items.isEmpty) return null;
    if (selectedItemId != null) {
      final found = scanResult.items.firstWhereOrNull(
        (e) => e.id == selectedItemId,
      );
      if (found != null) return found;
    }
    return scanResult.items.first;
  }

  ScannerState copyWith({
    ScannerCapabilities? capabilities,
    bool? isFrozen,
    String? frozenImagePath,
    bool clearFrozenImage = false,
    bool? isAnalyzingStill,
    bool? isDownloadingModel,
    String? lockedSourceCurrency,
    bool clearLockedSourceCurrency = false,
    String? locationCurrencyCode,
    String? locationCountryCode,
    ScanAnalysisResult? scanResult,
    String? selectedItemId,
    bool clearSelectedItem = false,
    bool? isAskingAgent,
    AgentQueryResult? agentResponse,
    bool clearAgentResponse = false,
    String? errorMessage,
    bool clearError = false,
  }) {
    return ScannerState(
      capabilities: capabilities ?? this.capabilities,
      isFrozen: isFrozen ?? this.isFrozen,
      frozenImagePath: clearFrozenImage
          ? null
          : (frozenImagePath ?? this.frozenImagePath),
      isAnalyzingStill: isAnalyzingStill ?? this.isAnalyzingStill,
      isDownloadingModel: isDownloadingModel ?? this.isDownloadingModel,
      lockedSourceCurrency: clearLockedSourceCurrency
          ? null
          : (lockedSourceCurrency ?? this.lockedSourceCurrency),
      locationCurrencyCode: locationCurrencyCode ?? this.locationCurrencyCode,
      locationCountryCode: locationCountryCode ?? this.locationCountryCode,
      scanResult: scanResult ?? this.scanResult,
      selectedItemId: clearSelectedItem
          ? null
          : (selectedItemId ?? this.selectedItemId),
      isAskingAgent: isAskingAgent ?? this.isAskingAgent,
      agentResponse: clearAgentResponse
          ? null
          : (agentResponse ?? this.agentResponse),
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }
}

class ScannerNotifier extends Notifier<ScannerState> {
  static const int _liveThrottleMs = 350;
  static const int _emptyFrameGraceCount = 5;

  final log = Logger('ScannerNotifier');
  bool _isProcessingLiveFrame = false;
  bool _isPausedForPicker = false;
  bool _locationPermissionRequested = false;
  DateTime _lastFrameAnalyzed = DateTime.fromMillisecondsSinceEpoch(0);

  // Temporal stabilization state for jitter-free live scanning
  int _consecutiveEmptyFrames = 0;
  double? _pendingSwitchAmount;
  int _pendingSwitchStreak = 0;

  IPriceScannerService get _service => spot<IPriceScannerService>();

  @override
  ScannerState build() {
    ref.onDispose(() {
      _service.disposeSession();
    });
    return const ScannerState();
  }

  Future<void> initializeCapabilities() async {
    final capsFuture = _service.getCapabilities();
    // Step 1: Instant zero-prompt check (cached location / cellular network / timezone)
    final quickLocFuture = _service.detectLocationCurrency(
      requestPermission: false,
    );

    final caps = await capsFuture;
    final quickLoc = await quickLocFuture;

    state = state.copyWith(
      capabilities: caps,
      locationCurrencyCode: quickLoc?.currencyCode,
      locationCountryCode: quickLoc?.countryCode,
    );

    // Step 2: If we don't have GPS confirmation yet, request coarse location permission once
    if (!_locationPermissionRequested && quickLoc?.source != 'gps') {
      _locationPermissionRequested = true;
      final refinedLoc = await _service.detectLocationCurrency(
        requestPermission: true,
      );
      if (refinedLoc != null) {
        state = state.copyWith(
          locationCurrencyCode: refinedLoc.currencyCode,
          locationCountryCode: refinedLoc.countryCode,
        );
      }
    }
  }

  void setPausedForPicker(bool paused) {
    _isPausedForPicker = paused;
  }

  Future<void> downloadAiModel() async {
    if (state.isDownloadingModel) return;
    state = state.copyWith(isDownloadingModel: true, clearError: true);
    final ok = await _service.triggerModelDownload();
    final caps = await _service.getCapabilities();
    state = state.copyWith(
      isDownloadingModel: false,
      capabilities: caps,
      errorMessage: ok ? null : 'Unable to download on-device AI model.',
    );
  }

  Future<void> processLiveFrame({
    required Uint8List bytes,
    required int width,
    required int height,
    required int rotationDegrees,
    required String imageFormat,
    int? bytesPerRow,
  }) async {
    if (!FeatureFlags.enableLiveCameraConversion) return;
    if (state.isFrozen || _isProcessingLiveFrame || _isPausedForPicker) return;

    final now = DateTime.now();
    if (now.difference(_lastFrameAnalyzed).inMilliseconds < _liveThrottleMs) {
      return;
    }

    _isProcessingLiveFrame = true;
    _lastFrameAnalyzed = now;

    try {
      final selectedSymbols = ref
          .read(sortedCurrenciesProvider)
          .map((c) => c.symbol)
          .toList();

      final rawResult = await _service.scanLiveFrame(
        bytes: bytes,
        width: width,
        height: height,
        rotationDegrees: rotationDegrees,
        imageFormat: imageFormat,
        bytesPerRow: bytesPerRow,
        selectedCurrencies: selectedSymbols,
        lockedSourceCurrency: state.lockedSourceCurrency,
        locationCurrency: state.locationCurrencyCode,
      );

      // Ignore late live frame results if user already froze or opened picker
      if (state.isFrozen || _isPausedForPicker) return;

      _applyStabilizedLiveResult(rawResult);
    } finally {
      _isProcessingLiveFrame = false;
    }
  }

  void _applyStabilizedLiveResult(ScanAnalysisResult rawResult) {
    final deduped = _deduplicateAndSort(rawResult.items);

    // Grace period: hold last valid price for ~1.75s so momentary motion blur
    // doesn't collapse or flash the UI.
    if (deduped.isEmpty) {
      _pendingSwitchAmount = null;
      _pendingSwitchStreak = 0;
      if (state.scanResult.items.isNotEmpty) {
        _consecutiveEmptyFrames++;
        if (_consecutiveEmptyFrames >= _emptyFrameGraceCount) {
          _consecutiveEmptyFrames = 0;
          state = state.copyWith(
            scanResult: ScanAnalysisResult(
              items: const [],
              inferredCurrencyCode:
                  state.lockedSourceCurrency ?? state.locationCurrencyCode,
              tierUsed: rawResult.tierUsed,
              imageWidth: rawResult.imageWidth,
              imageHeight: rawResult.imageHeight,
            ),
            clearSelectedItem: true,
          );
        }
      }
      return;
    }

    _consecutiveEmptyFrames = 0;

    final stabilizedResult = ScanAnalysisResult(
      items: deduped,
      inferredCurrencyCode:
          state.lockedSourceCurrency ?? rawResult.inferredCurrencyCode,
      inferenceReason: rawResult.inferenceReason,
      tierUsed: rawResult.tierUsed,
      imageWidth: rawResult.imageWidth,
      imageHeight: rawResult.imageHeight,
    );

    final currentSelected = state.selectedItem;
    final centered = _pickClosestToCenter(deduped);

    // Case 1: Nothing currently displayed.
    // Require 2 consecutive frames for bare numbers (no currency symbol) to
    // suppress transient single-frame OCR noise; explicit currency prices show immediately.
    if (currentSelected == null) {
      final hasExplicitSymbol = centered.rawCurrencySymbol != null;
      if (!hasExplicitSymbol) {
        if (_pendingSwitchAmount != null &&
            (_pendingSwitchAmount! - centered.normalizedAmount).abs() < 0.01) {
          _pendingSwitchStreak++;
        } else {
          _pendingSwitchAmount = centered.normalizedAmount;
          _pendingSwitchStreak = 1;
        }
        if (_pendingSwitchStreak < 2) {
          return;
        }
      }
      _pendingSwitchAmount = null;
      _pendingSwitchStreak = 0;
      state = state.copyWith(
        scanResult: stabilizedResult,
        selectedItemId: centered.id,
      );
      return;
    }

    // Case 2: Current price is still visible in the frame -> keep it sticky
    // unless a different price is dramatically closer to center for 2 consecutive frames.
    final matchingCurrent = deduped.firstWhereOrNull(
      (item) =>
          (item.normalizedAmount - currentSelected.normalizedAmount).abs() <
          0.01,
    );

    if (matchingCurrent != null) {
      final currentDist = _centerDistSq(matchingCurrent);
      final bestDist = _centerDistSq(centered);
      final shouldSwitch = centered.id != matchingCurrent.id &&
          bestDist < currentDist * 0.45;

      if (shouldSwitch) {
        if (_pendingSwitchAmount != null &&
            (_pendingSwitchAmount! - centered.normalizedAmount).abs() < 0.01) {
          _pendingSwitchStreak++;
        } else {
          _pendingSwitchAmount = centered.normalizedAmount;
          _pendingSwitchStreak = 1;
        }
        if (_pendingSwitchStreak >= 2) {
          _pendingSwitchAmount = null;
          _pendingSwitchStreak = 0;
          state = state.copyWith(
            scanResult: stabilizedResult,
            selectedItemId: centered.id,
          );
          return;
        }
      } else {
        _pendingSwitchAmount = null;
        _pendingSwitchStreak = 0;
      }

      state = state.copyWith(
        scanResult: stabilizedResult,
        selectedItemId: matchingCurrent.id,
      );
      return;
    }

    // Case 3: Current price disappeared and a new price appeared.
    // Confirm the new price across 2 consecutive frames before switching so
    // single-frame OCR glitches (e.g. 450 -> 45) never flicker the display.
    if (_pendingSwitchAmount != null &&
        (_pendingSwitchAmount! - centered.normalizedAmount).abs() < 0.01) {
      _pendingSwitchStreak++;
    } else {
      _pendingSwitchAmount = centered.normalizedAmount;
      _pendingSwitchStreak = 1;
    }

    if (_pendingSwitchStreak >= 2) {
      _pendingSwitchAmount = null;
      _pendingSwitchStreak = 0;
      state = state.copyWith(
        scanResult: stabilizedResult,
        selectedItemId: centered.id,
      );
    }
  }

  Future<void> analyzeFrozenPhoto(String imagePath) async {
    _consecutiveEmptyFrames = 0;
    _pendingSwitchAmount = null;
    _pendingSwitchStreak = 0;

    state = state.copyWith(
      isFrozen: true,
      frozenImagePath: imagePath,
      isAnalyzingStill: true,
      clearAgentResponse: true,
      clearError: true,
    );

    final selectedSymbols = ref
        .read(sortedCurrenciesProvider)
        .map((c) => c.symbol)
        .toList();

    final result = await _service.analyzeCapturedImage(
      imagePath: imagePath,
      selectedCurrencies: selectedSymbols,
      lockedSourceCurrency: state.lockedSourceCurrency,
      locationCurrency: state.locationCurrencyCode,
    );

    final deduped = _deduplicateAndSort(result.items);
    final cleanResult = ScanAnalysisResult(
      items: deduped,
      inferredCurrencyCode:
          state.lockedSourceCurrency ?? result.inferredCurrencyCode,
      inferenceReason: result.inferenceReason,
      tierUsed: result.tierUsed,
      imageWidth: result.imageWidth,
      imageHeight: result.imageHeight,
    );

    state = state.copyWith(
      isAnalyzingStill: false,
      scanResult: cleanResult,
      selectedItemId: deduped.firstOrNull?.id,
      clearSelectedItem: deduped.isEmpty,
    );
  }

  void resumeLivePreview() {
    _service.disposeSession();
    _consecutiveEmptyFrames = 0;
    _pendingSwitchAmount = null;
    _pendingSwitchStreak = 0;
    state = state.copyWith(
      isFrozen: false,
      clearFrozenImage: true,
      isAnalyzingStill: false,
      scanResult: ScanAnalysisResult.empty,
      clearSelectedItem: true,
      clearAgentResponse: true,
      clearError: true,
    );
  }

  void setLockedSourceCurrency(String? symbol) {
    final normalizedSymbol = symbol?.trim().toUpperCase();
    final effectiveForItems =
        (normalizedSymbol != null && normalizedSymbol.isNotEmpty)
            ? normalizedSymbol
            : state.locationCurrencyCode;

    final updatedItems = state.scanResult.items.map((item) {
      final reparsedAmount = item.isShorthandMultiplied
          ? item.normalizedAmount
          : (PriceTextParser.parseSingleAmount(
                item.rawText,
                currencyCode: effectiveForItems,
              ) ??
              item.normalizedAmount);
      final isInflated = effectiveForItems != null &&
          inflatedCurrencies.contains(effectiveForItems);
      final isWholeSmall = !item.isShorthandMultiplied &&
          reparsedAmount == reparsedAmount.floorToDouble() &&
          reparsedAmount >= 1 &&
          reparsedAmount < 1000;
      return item.copyWith(
        normalizedAmount: reparsedAmount,
        detectedCurrencyCode: normalizedSymbol ?? item.detectedCurrencyCode,
        canToggleThousandsShorthand: isInflated && isWholeSmall,
      );
    }).toList();

    final updatedScan = ScanAnalysisResult(
      items: updatedItems,
      inferredCurrencyCode: normalizedSymbol ?? state.locationCurrencyCode,
      inferenceReason: normalizedSymbol != null
          ? 'Manual selection'
          : (state.locationCurrencyCode != null
              ? 'Detected from location'
              : null),
      tierUsed: state.scanResult.tierUsed,
      imageWidth: state.scanResult.imageWidth,
      imageHeight: state.scanResult.imageHeight,
    );

    if (normalizedSymbol == null || normalizedSymbol.isEmpty) {
      state = state.copyWith(
        clearLockedSourceCurrency: true,
        scanResult: updatedScan,
        clearAgentResponse: true,
      );
    } else {
      state = state.copyWith(
        lockedSourceCurrency: normalizedSymbol,
        scanResult: updatedScan,
        clearAgentResponse: true,
      );
    }
  }

  void selectItem(String itemId) {
    _pendingSwitchAmount = null;
    _pendingSwitchStreak = 0;
    state = state.copyWith(selectedItemId: itemId);
  }

  void toggleThousandsShorthand(String itemId) {
    final updatedItems = state.scanResult.items.map((item) {
      if (item.id != itemId) return item;
      final nextMultiplied = !item.isShorthandMultiplied;
      final nextAmount = nextMultiplied
          ? item.normalizedAmount * 1000.0
          : item.normalizedAmount / 1000.0;
      return item.copyWith(
        normalizedAmount: nextAmount,
        isShorthandMultiplied: nextMultiplied,
      );
    }).toList();

    state = state.copyWith(
      scanResult: ScanAnalysisResult(
        items: updatedItems,
        inferredCurrencyCode: state.scanResult.inferredCurrencyCode,
        inferenceReason: state.scanResult.inferenceReason,
        tierUsed: state.scanResult.tierUsed,
        imageWidth: state.scanResult.imageWidth,
        imageHeight: state.scanResult.imageHeight,
      ),
    );
  }

  Future<void> askAgent(String prompt) async {
    final trimmed = prompt.trim();
    if (trimmed.isEmpty || state.isAskingAgent) return;

    state = state.copyWith(isAskingAgent: true, clearError: true);

    final selectedSymbols = ref
        .read(sortedCurrenciesProvider)
        .map((c) => c.symbol)
        .toList();
    final allCurrencies = ref.read(currenciesProvider).currencies;
    final ratesMap = <String, double>{
      'USD': 1.0,
      for (final c in allCurrencies)
        if (c.rate > 0) c.symbol: c.rate,
    };

    final sourceCurrency = state.effectiveSourceCurrency(selectedSymbols);

    final answer = await _service.askAgent(
      prompt: trimmed,
      currentScan: state.scanResult,
      sourceCurrency: sourceCurrency,
      ratesBySymbol: ratesMap,
      selectedCurrencies: selectedSymbols,
    );

    state = state.copyWith(
      isAskingAgent: false,
      agentResponse: answer,
    );
  }

  List<ScannedPriceItem> _deduplicateAndSort(List<ScannedPriceItem> items) {
    if (items.isEmpty) return const [];
    // Deduplicate identical numeric prices (keeping the one closest to center)
    final Map<String, ScannedPriceItem> byAmount = {};
    for (final item in items) {
      final key = item.normalizedAmount.toStringAsFixed(2);
      final existing = byAmount[key];
      if (existing == null || _centerDistSq(item) < _centerDistSq(existing)) {
        byAmount[key] = item;
      }
    }
    final deduped = byAmount.values.toList();
    // Deterministic top-to-bottom, left-to-right ordering so chips don't shuffle
    deduped.sort((a, b) {
      final aTop = a.boundingBox?.top ?? 0.5;
      final bTop = b.boundingBox?.top ?? 0.5;
      final topDiff = (aTop - bTop).abs();
      if (topDiff > 0.03) return aTop.compareTo(bTop);
      final aLeft = a.boundingBox?.left ?? 0.5;
      final bLeft = b.boundingBox?.left ?? 0.5;
      return aLeft.compareTo(bLeft);
    });
    return deduped;
  }

  double _centerDistSq(ScannedPriceItem item) {
    final box = item.boundingBox;
    if (box == null) return 1.0;
    final dx = box.centerX - 0.5;
    final dy = box.centerY - 0.5;
    return dx * dx + dy * dy;
  }

  ScannedPriceItem _pickClosestToCenter(List<ScannedPriceItem> items) {
    ScannedPriceItem best = items.first;
    double bestDistSq = _centerDistSq(best);

    for (final item in items.skip(1)) {
      final distSq = _centerDistSq(item);
      if (distSq < bestDistSq) {
        bestDistSq = distSq;
        best = item;
      }
    }
    return best;
  }
}

final scannerProvider = NotifierProvider<ScannerNotifier, ScannerState>(
  ScannerNotifier.new,
);
