import 'dart:typed_data';

import 'package:grana/domain/models/scanned_price.dart';

abstract class IPriceScannerService {
  Future<ScannerCapabilities> getCapabilities();

  Future<LocationCurrencyResult?> detectLocationCurrency({
    bool requestPermission = false,
  });

  Future<bool> triggerModelDownload();

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
  });

  Future<ScanAnalysisResult> analyzeCapturedImage({
    required String imagePath,
    required List<String> selectedCurrencies,
    String? lockedSourceCurrency,
    String? locationCurrency,
  });

  Future<AgentQueryResult> askAgent({
    required String prompt,
    required ScanAnalysisResult currentScan,
    required String sourceCurrency,
    required Map<String, double> ratesBySymbol,
    required List<String> selectedCurrencies,
  });

  Future<void> disposeSession();
}
