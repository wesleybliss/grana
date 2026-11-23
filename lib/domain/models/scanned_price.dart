import 'package:flutter/foundation.dart';

enum AiScannerTier {
  geminiNano4,
  appleIntelligence,
  onDeviceOcr,
  unsupported,
}

enum ModelAvailabilityStatus {
  available,
  downloadable,
  downloading,
  unavailable,
}

@immutable
class ScannerCapabilities {
  final bool isSupported;
  final AiScannerTier activeTier;
  final ModelAvailabilityStatus llmStatus;

  const ScannerCapabilities({
    required this.isSupported,
    required this.activeTier,
    required this.llmStatus,
  });

  bool get hasOnDeviceLlm =>
      (activeTier == AiScannerTier.geminiNano4 ||
          activeTier == AiScannerTier.appleIntelligence) &&
      llmStatus == ModelAvailabilityStatus.available;

  static const unsupported = ScannerCapabilities(
    isSupported: false,
    activeTier: AiScannerTier.unsupported,
    llmStatus: ModelAvailabilityStatus.unavailable,
  );
}

@immutable
class NormalizedRect {
  final double left;
  final double top;
  final double width;
  final double height;

  const NormalizedRect({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  double get right => (left + width).clamp(0.0, 1.0);
  double get bottom => (top + height).clamp(0.0, 1.0);
  double get centerX => left + width / 2.0;
  double get centerY => top + height / 2.0;

  factory NormalizedRect.fromMap(Map<dynamic, dynamic> map) {
    return NormalizedRect(
      left: ((map['left'] as num?)?.toDouble() ?? 0.0).clamp(0.0, 1.0),
      top: ((map['top'] as num?)?.toDouble() ?? 0.0).clamp(0.0, 1.0),
      width: ((map['width'] as num?)?.toDouble() ?? 0.0).clamp(0.0, 1.0),
      height: ((map['height'] as num?)?.toDouble() ?? 0.0).clamp(0.0, 1.0),
    );
  }

  Map<String, double> toMap() => {
        'left': left,
        'top': top,
        'width': width,
        'height': height,
      };
}

@immutable
class OcrTextLine {
  final String text;
  final NormalizedRect? boundingBox;

  const OcrTextLine({
    required this.text,
    this.boundingBox,
  });

  factory OcrTextLine.fromMap(Map<dynamic, dynamic> map) {
    final boxMap = map['boundingBox'] as Map<dynamic, dynamic>?;
    return OcrTextLine(
      text: (map['text'] as String?) ?? '',
      boundingBox: boxMap != null ? NormalizedRect.fromMap(boxMap) : null,
    );
  }
}

@immutable
class ScannedPriceItem {
  final String id;
  final String rawText;
  final String? itemLabel;
  final double normalizedAmount;
  final String? detectedCurrencyCode;
  final String? rawCurrencySymbol;
  final NormalizedRect? boundingBox;
  final bool isShorthandMultiplied;
  final bool canToggleThousandsShorthand;

  const ScannedPriceItem({
    required this.id,
    required this.rawText,
    required this.normalizedAmount,
    this.itemLabel,
    this.detectedCurrencyCode,
    this.rawCurrencySymbol,
    this.boundingBox,
    this.isShorthandMultiplied = false,
    this.canToggleThousandsShorthand = false,
  });

  ScannedPriceItem copyWith({
    String? id,
    String? rawText,
    String? itemLabel,
    double? normalizedAmount,
    String? detectedCurrencyCode,
    String? rawCurrencySymbol,
    NormalizedRect? boundingBox,
    bool? isShorthandMultiplied,
    bool? canToggleThousandsShorthand,
  }) {
    return ScannedPriceItem(
      id: id ?? this.id,
      rawText: rawText ?? this.rawText,
      itemLabel: itemLabel ?? this.itemLabel,
      normalizedAmount: normalizedAmount ?? this.normalizedAmount,
      detectedCurrencyCode: detectedCurrencyCode ?? this.detectedCurrencyCode,
      rawCurrencySymbol: rawCurrencySymbol ?? this.rawCurrencySymbol,
      boundingBox: boundingBox ?? this.boundingBox,
      isShorthandMultiplied:
          isShorthandMultiplied ?? this.isShorthandMultiplied,
      canToggleThousandsShorthand:
          canToggleThousandsShorthand ?? this.canToggleThousandsShorthand,
    );
  }
}

@immutable
class ScanAnalysisResult {
  final List<ScannedPriceItem> items;
  final String? inferredCurrencyCode;
  final String? inferenceReason;
  final AiScannerTier tierUsed;
  final int imageWidth;
  final int imageHeight;

  const ScanAnalysisResult({
    required this.items,
    required this.tierUsed,
    this.inferredCurrencyCode,
    this.inferenceReason,
    this.imageWidth = 1,
    this.imageHeight = 1,
  });

  static const empty = ScanAnalysisResult(
    items: [],
    tierUsed: AiScannerTier.onDeviceOcr,
  );
}

@immutable
class LocationCurrencyResult {
  final String currencyCode;
  final String? countryCode;
  final String? source;

  const LocationCurrencyResult({
    required this.currencyCode,
    this.countryCode,
    this.source,
  });
}

@immutable
class AgentQueryResult {
  final String responseText;
  final List<String> invokedTools;
  final double? computedAmountInSource;

  const AgentQueryResult({
    required this.responseText,
    this.invokedTools = const [],
    this.computedAmountInSource,
  });
}
