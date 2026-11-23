import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import 'package:grana/config/flavor.dart';
import 'package:grana/domain/io/services/i_price_scanner_service.dart';
import 'package:grana/domain/models/scanned_price.dart';
import 'package:grana/utils/currency_utils.dart';
import 'package:grana/utils/logger.dart';
import 'package:grana/utils/price_text_parser.dart';

class PriceScannerService implements IPriceScannerService {
  static const MethodChannel _channel = MethodChannel(
    'com.gammagamma.grana/price_scanner',
  );

  final log = Logger('PriceScannerService');

  @override
  Future<ScannerCapabilities> getCapabilities() async {
    if (FlavorConfig.isFossBuild) {
      return ScannerCapabilities.unsupported;
    }

    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'getCapabilities',
      );
      if (result == null) return ScannerCapabilities.unsupported;

      final isSupported = (result['isSupported'] as bool?) ?? false;
      final tierRaw = (result['activeTier'] as String?) ?? 'onDeviceOcr';
      final llmStatusRaw = (result['llmStatus'] as String?) ?? 'unavailable';

      return ScannerCapabilities(
        isSupported: isSupported,
        activeTier: _parseTier(tierRaw),
        llmStatus: _parseLlmStatus(llmStatusRaw),
      );
    } on MissingPluginException {
      return ScannerCapabilities.unsupported;
    } catch (e) {
      log.w('getCapabilities error: $e');
      return ScannerCapabilities.unsupported;
    }
  }

  @override
  Future<LocationCurrencyResult?> detectLocationCurrency({
    bool requestPermission = false,
  }) async {
    if (FlavorConfig.isFossBuild) return null;

    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'detectLocationCurrency',
        {'requestPermission': requestPermission},
      );
      if (result == null) return null;
      final currencyCode = (result['currencyCode'] as String?)?.trim().toUpperCase();
      if (currencyCode == null || currencyCode.length != 3) return null;
      final countryCode = (result['countryCode'] as String?)?.trim().toUpperCase();
      final source = (result['source'] as String?)?.trim();
      return LocationCurrencyResult(
        currencyCode: currencyCode,
        countryCode: countryCode,
        source: source,
      );
    } on MissingPluginException {
      return null;
    } catch (e) {
      log.w('detectLocationCurrency error: $e');
      return null;
    }
  }

  @override
  Future<bool> triggerModelDownload() async {
    if (FlavorConfig.isFossBuild) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('downloadModel');
      return ok ?? false;
    } catch (e) {
      log.w('triggerModelDownload error: $e');
      return false;
    }
  }

  @override
  Future<ScanAnalysisResult> scanLiveFrame({
    required Uint8List bytes,
    required int width,
    required int height,
    required int rotationDegrees,
    required String imageFormat,
    int? bytesPerRow,
    required List<String> selectedCurrencies,
    String? lockedSourceCurrency,
    String? locationCurrency,
  }) async {
    if (FlavorConfig.isFossBuild) return ScanAnalysisResult.empty;

    try {
      final response = await _channel.invokeMapMethod<String, dynamic>(
        'recognizeLiveFrame',
        {
          'bytes': bytes,
          'width': width,
          'height': height,
          'rotationDegrees': rotationDegrees,
          'imageFormat': imageFormat,
          'bytesPerRow': bytesPerRow ?? width,
        },
      );
      if (response == null) return ScanAnalysisResult.empty;

      final rawLines = (response['lines'] as List<dynamic>?) ?? const [];
      final ocrLines = rawLines
          .whereType<Map<dynamic, dynamic>>()
          .map(OcrTextLine.fromMap)
          .toList();

      final frameWidth = (response['imageWidth'] as num?)?.toInt() ?? width;
      final frameHeight = (response['imageHeight'] as num?)?.toInt() ?? height;

      return PriceTextParser.parseOcrLines(
        ocrLines,
        selectedCurrencies: selectedCurrencies,
        lockedSourceCurrency: lockedSourceCurrency,
        locationCurrency: locationCurrency,
        imageWidth: frameWidth,
        imageHeight: frameHeight,
      );
    } catch (e) {
      log.d('scanLiveFrame skipped/failed: $e');
      return ScanAnalysisResult.empty;
    }
  }

  @override
  Future<ScanAnalysisResult> analyzeCapturedImage({
    required String imagePath,
    required List<String> selectedCurrencies,
    String? lockedSourceCurrency,
    String? locationCurrency,
  }) async {
    if (FlavorConfig.isFossBuild) return ScanAnalysisResult.empty;

    try {
      final response = await _channel.invokeMapMethod<String, dynamic>(
        'analyzeImageSmart',
        {
          'imagePath': imagePath,
          'selectedCurrencies': selectedCurrencies,
          'lockedSourceCurrency': lockedSourceCurrency,
          'locationCurrency': locationCurrency,
        },
      );
      if (response == null) return ScanAnalysisResult.empty;

      final rawLines = (response['lines'] as List<dynamic>?) ?? const [];
      final ocrLines = rawLines
          .whereType<Map<dynamic, dynamic>>()
          .map(OcrTextLine.fromMap)
          .toList();

      final imageWidth = (response['imageWidth'] as num?)?.toInt() ?? 1;
      final imageHeight = (response['imageHeight'] as num?)?.toInt() ?? 1;
      final tierUsed = _parseTier(
        (response['tierUsed'] as String?) ?? 'onDeviceOcr',
      );

      // Start with deterministic OCR + bounding-box parse as baseline
      final baseline = PriceTextParser.parseOcrLines(
        ocrLines,
        selectedCurrencies: selectedCurrencies,
        lockedSourceCurrency: lockedSourceCurrency,
        locationCurrency: locationCurrency,
        imageWidth: imageWidth,
        imageHeight: imageHeight,
      );

      final aiItemsRaw = (response['aiItems'] as List<dynamic>?) ?? const [];
      final aiCurrencyRaw = (response['inferredCurrency'] as String?)?.trim().toUpperCase();
      final aiReason = response['inferenceReason'] as String?;

      // If no explicit currency code/unambiguous symbol appeared in OCR text,
      // prevent an on-device LLM from overriding the user's physical location
      // currency when interpreting an ambiguous symbol like "$".
      final ocrFullText = ocrLines.map((l) => l.text).join('\n');
      final explicitOcrCurrency =
          PriceTextParser.inferExplicitContextualCurrency(ocrFullText);
      final normalizedAiCurrency =
          (aiCurrencyRaw != null && PriceTextParser.knownIsoCodes.contains(aiCurrencyRaw))
              ? aiCurrencyRaw
              : null;
      final preferredInferredCurrency = lockedSourceCurrency ??
          explicitOcrCurrency ??
          locationCurrency ??
          normalizedAiCurrency ??
          baseline.inferredCurrencyCode;

      if (aiItemsRaw.isEmpty) {
        return ScanAnalysisResult(
          items: baseline.items,
          inferredCurrencyCode: preferredInferredCurrency,
          inferenceReason: aiReason ?? baseline.inferenceReason,
          tierUsed: tierUsed,
          imageWidth: imageWidth,
          imageHeight: imageHeight,
        );
      }

      final List<ScannedPriceItem> mergedItems = [];
      for (var i = 0; i < aiItemsRaw.length; i++) {
        final map = aiItemsRaw[i];
        if (map is! Map<dynamic, dynamic>) continue;

        final rawAiAmount = (map['normalizedAmount'] as num?)?.toDouble();
        if (rawAiAmount == null || rawAiAmount <= 0) continue;

        final rawPriceText =
            (map['rawText'] as String?) ?? rawAiAmount.toStringAsFixed(2);
        final itemExplicitCurrency =
            PriceTextParser.inferExplicitContextualCurrency(rawPriceText);
        final itemAiCurrency = (map['currencyCode'] as String?)?.trim().toUpperCase();
        final validItemAiCurrency = (itemAiCurrency != null &&
                PriceTextParser.knownIsoCodes.contains(itemAiCurrency))
            ? itemAiCurrency
            : null;
        final detectedCode = lockedSourceCurrency ??
            itemExplicitCurrency ??
            (locationCurrency != null && explicitOcrCurrency == null
                ? locationCurrency
                : validItemAiCurrency) ??
            preferredInferredCurrency;
        final isShorthand = (map['isShorthandMultiplied'] as bool?) ?? false;

        final amount = PriceTextParser.reconcileAiAmount(
          rawText: rawPriceText,
          aiAmount: rawAiAmount,
          currencyCode: detectedCode,
          isShorthandMultiplied: isShorthand,
        );

        final matchedBox = _matchBoundingBox(
          rawText: rawPriceText,
          amount: amount,
          baselineItems: baseline.items,
          ocrLines: ocrLines,
        );

        final isInflated =
            detectedCode != null && inflatedCurrencies.contains(detectedCode);
        final isWholeSmallNumber = !isShorthand &&
            amount == amount.floorToDouble() &&
            amount >= 1 &&
            amount < 1000;

        mergedItems.add(
          ScannedPriceItem(
            id: 'ai_$i',
            rawText: rawPriceText,
            itemLabel: null,
            normalizedAmount: amount,
            detectedCurrencyCode: detectedCode,
            boundingBox: matchedBox,
            isShorthandMultiplied: isShorthand,
            canToggleThousandsShorthand: isInflated && isWholeSmallNumber,
          ),
        );
      }

      return ScanAnalysisResult(
        items: mergedItems.isNotEmpty ? mergedItems : baseline.items,
        inferredCurrencyCode: preferredInferredCurrency,
        inferenceReason: aiReason ?? baseline.inferenceReason,
        tierUsed: tierUsed,
        imageWidth: imageWidth,
        imageHeight: imageHeight,
      );
    } catch (e) {
      log.w('analyzeCapturedImage error: $e');
      return ScanAnalysisResult.empty;
    }
  }

  @override
  Future<AgentQueryResult> askAgent({
    required String prompt,
    required ScanAnalysisResult currentScan,
    required String sourceCurrency,
    required Map<String, double> ratesBySymbol,
    required List<String> selectedCurrencies,
  }) async {
    final itemsPayload = currentScan.items
        .map(
          (e) => {
            'amount': e.normalizedAmount,
            'rawText': e.rawText,
          },
        )
        .toList();

    try {
      final response = await _channel.invokeMapMethod<String, dynamic>(
        'askAgent',
        {
          'prompt': prompt,
          'sourceCurrency': sourceCurrency,
          'selectedCurrencies': selectedCurrencies,
          'ratesBySymbol': ratesBySymbol,
          'items': itemsPayload,
        },
      );

      if (response != null && (response['handledByNativeAgent'] as bool? ?? false)) {
        final text = (response['responseText'] as String?) ?? '';
        final tools = ((response['invokedTools'] as List<dynamic>?) ?? const [])
            .map((e) => e.toString())
            .toList();
        final computed = (response['computedAmountInSource'] as num?)?.toDouble();
        if (text.trim().isNotEmpty) {
          return AgentQueryResult(
            responseText: text.trim(),
            invokedTools: tools,
            computedAmountInSource: computed,
          );
        }
      }
    } catch (e) {
      log.w('Native askAgent unavailable, using local calculator tool fallback: $e');
    }

    return _runDeterministicLocalTool(
      prompt: prompt,
      currentScan: currentScan,
      sourceCurrency: sourceCurrency,
      ratesBySymbol: ratesBySymbol,
      selectedCurrencies: selectedCurrencies,
    );
  }

  @override
  Future<void> disposeSession() async {
    if (FlavorConfig.isFossBuild) return;
    try {
      await _channel.invokeMethod<void>('disposeSession');
    } catch (_) {}
  }

  NormalizedRect? _matchBoundingBox({
    required String rawText,
    required double amount,
    required List<ScannedPriceItem> baselineItems,
    required List<OcrTextLine> ocrLines,
  }) {
    for (final base in baselineItems) {
      if ((base.normalizedAmount - amount).abs() < 0.01 &&
          base.boundingBox != null) {
        return base.boundingBox;
      }
    }
    final cleanToken = rawText.replaceAll(RegExp(r'[^\d.,]'), '');
    if (cleanToken.isNotEmpty) {
      for (final line in ocrLines) {
        if (line.text.contains(cleanToken) && line.boundingBox != null) {
          return line.boundingBox;
        }
      }
    }
    return null;
  }

  AgentQueryResult _runDeterministicLocalTool({
    required String prompt,
    required ScanAnalysisResult currentScan,
    required String sourceCurrency,
    required Map<String, double> ratesBySymbol,
    required List<String> selectedCurrencies,
  }) {
    final lower = prompt.toLowerCase();
    final items = currentScan.items;
    if (items.isEmpty) {
      return const AgentQueryResult(
        responseText: 'No detected prices to calculate yet.',
      );
    }

    double subtotal = items.fold(
      0.0,
      (sum, item) => sum + item.normalizedAmount,
    );

    final tipMatch = RegExp(r'(\d+(?:\.\d+)?)\s*%').firstMatch(lower);
    final tipPercent = tipMatch != null
        ? (double.tryParse(tipMatch.group(1)!) ?? 0.0)
        : (lower.contains('tip') ? 15.0 : 0.0);

    final splitMatch = RegExp(
      r'(?:split|divide|between|ways?)\s*(?:by\s*)?(\d+)|(\d+)\s*(?:ways?|people|persons)',
    ).firstMatch(lower);
    final splitCount = splitMatch != null
        ? (int.tryParse(splitMatch.group(1) ?? splitMatch.group(2) ?? '1') ?? 1)
            .clamp(1, 100)
        : 1;

    final totalWithTip = subtotal * (1.0 + tipPercent / 100.0);
    final perPerson = totalWithTip / splitCount;

    final sourceRate = sourceCurrency == 'USD'
        ? 1.0
        : (ratesBySymbol[sourceCurrency] ?? 1.0);
    final usdAmount = sourceRate > 0 ? perPerson / sourceRate : perPerson;

    final fmt = NumberFormat('#,##0.00');
    final conversions = selectedCurrencies
        .where((c) => c != sourceCurrency && ratesBySymbol.containsKey(c))
        .take(4)
        .map((c) => '${fmt.format(usdAmount * ratesBySymbol[c]!)} $c')
        .join(' • ');

    final StringBuffer summary = StringBuffer();
    if (tipPercent > 0 && splitCount > 1) {
      summary.write(
        'Subtotal ${fmt.format(subtotal)} $sourceCurrency + ${tipPercent.toStringAsFixed(0)}% tip ÷ $splitCount = ${fmt.format(perPerson)} $sourceCurrency each',
      );
    } else if (tipPercent > 0) {
      summary.write(
        'Subtotal ${fmt.format(subtotal)} $sourceCurrency + ${tipPercent.toStringAsFixed(0)}% tip = ${fmt.format(totalWithTip)} $sourceCurrency',
      );
    } else if (splitCount > 1) {
      summary.write(
        'Total ${fmt.format(subtotal)} $sourceCurrency ÷ $splitCount = ${fmt.format(perPerson)} $sourceCurrency each',
      );
    } else {
      summary.write(
        'Total (${items.length} item${items.length == 1 ? '' : 's'}): ${fmt.format(subtotal)} $sourceCurrency',
      );
    }

    if (conversions.isNotEmpty) {
      summary.write('\n→ $conversions');
    }

    return AgentQueryResult(
      responseText: summary.toString(),
      invokedTools: const ['local_calculator'],
      computedAmountInSource: perPerson,
    );
  }

  AiScannerTier _parseTier(String raw) {
    return switch (raw) {
      'geminiNano4' => AiScannerTier.geminiNano4,
      'appleIntelligence' => AiScannerTier.appleIntelligence,
      'onDeviceOcr' => AiScannerTier.onDeviceOcr,
      _ => AiScannerTier.unsupported,
    };
  }

  ModelAvailabilityStatus _parseLlmStatus(String raw) {
    return switch (raw) {
      'available' => ModelAvailabilityStatus.available,
      'downloadable' => ModelAvailabilityStatus.downloadable,
      'downloading' => ModelAvailabilityStatus.downloading,
      _ => ModelAvailabilityStatus.unavailable,
    };
  }
}
