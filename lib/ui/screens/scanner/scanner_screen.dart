import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import 'package:grana/config/feature_flags.dart';
import 'package:grana/db/database.dart';
import 'package:grana/domain/di/providers/currencies/currencies_provider.dart';
import 'package:grana/domain/di/providers/currencies/sorted_currencies_provider.dart';
import 'package:grana/domain/di/providers/scanner/scanner_provider.dart';
import 'package:grana/domain/di/providers/settings/settings_provider.dart';
import 'package:grana/l10n/app_localizations.dart';
import 'package:grana/ui/screens/scanner/widgets/converted_prices_sheet.dart';
import 'package:grana/ui/screens/scanner/widgets/price_bounding_overlay.dart';
import 'package:grana/ui/screens/scanner/widgets/scanner_top_bar.dart';
import 'package:grana/ui/widgets/currency_inputs_list/currency_inputs_list_vm.dart';
import 'package:grana/utils/logger.dart';

class ScannerScreen extends ConsumerStatefulWidget {
  final bool enableLiveCameraConversion;

  const ScannerScreen({
    super.key,
    this.enableLiveCameraConversion = FeatureFlags.enableLiveCameraConversion,
  });

  @override
  ConsumerState<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends ConsumerState<ScannerScreen>
    with WidgetsBindingObserver {
  final log = Logger('ScannerScreen');
  final ImagePicker _imagePicker = ImagePicker();

  CameraController? _cameraController;
  bool _isInitializingCamera = true;
  bool _cameraUnavailableOrDenied = false;
  bool _isTorchOn = false;
  bool _isCapturing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(scannerProvider.notifier).initializeCapabilities();
      _initCamera();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _disposeCamera();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;

    if (state == AppLifecycleState.inactive) {
      _disposeCamera();
    } else if (state == AppLifecycleState.resumed) {
      if (!ref.read(scannerProvider).isFrozen) {
        _initCamera();
      }
    }
  }

  Future<void> _initCamera() async {
    final isTestEnv = WidgetsBinding.instance.runtimeType
        .toString()
        .contains('Test');
    if (isTestEnv) {
      if (mounted) {
        setState(() {
          _isInitializingCamera = false;
          _cameraUnavailableOrDenied = true;
        });
      }
      return;
    }

    if (mounted) {
      setState(() {
        _isInitializingCamera = true;
        _cameraUnavailableOrDenied = false;
      });
    }

    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        if (mounted) {
          setState(() {
            _isInitializingCamera = false;
            _cameraUnavailableOrDenied = true;
          });
        }
        return;
      }

      final backCamera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      final controller = CameraController(
        backCamera,
        ResolutionPreset.high,
        enableAudio: false,
        imageFormatGroup: (!kIsWeb && Platform.isAndroid)
            ? ImageFormatGroup.nv21
            : ImageFormatGroup.bgra8888,
      );

      await controller.initialize();
      if (widget.enableLiveCameraConversion) {
        await controller.startImageStream(_onCameraFrame);
      }

      if (!mounted) {
        await controller.dispose();
        return;
      }

      setState(() {
        _cameraController = controller;
        _isInitializingCamera = false;
        _cameraUnavailableOrDenied = false;
      });
    } catch (e) {
      log.w('Camera initialization unavailable or permission denied: $e');
      if (mounted) {
        setState(() {
          _isInitializingCamera = false;
          _cameraUnavailableOrDenied = true;
        });
      }
    }
  }

  Future<void> _disposeCamera() async {
    final controller = _cameraController;
    _cameraController = null;
    if (controller != null) {
      try {
        if (controller.value.isStreamingImages) {
          await controller.stopImageStream();
        }
      } catch (_) {}
      try {
        await controller.dispose();
      } catch (_) {}
    }
  }

  void _onCameraFrame(CameraImage image) {
    if (!mounted || !widget.enableLiveCameraConversion) return;
    final scannerState = ref.read(scannerProvider);
    if (scannerState.isFrozen) return;

    final controller = _cameraController;
    if (controller == null) return;

    final rotation = controller.description.sensorOrientation;

    if (!kIsWeb && Platform.isAndroid) {
      final nv21Bytes = _extractNv21Bytes(image);
      if (nv21Bytes == null) return;
      ref.read(scannerProvider.notifier).processLiveFrame(
            bytes: nv21Bytes,
            width: image.width,
            height: image.height,
            rotationDegrees: rotation,
            imageFormat: 'nv21',
          );
    } else if (image.planes.isNotEmpty) {
      ref.read(scannerProvider.notifier).processLiveFrame(
            bytes: image.planes.first.bytes,
            width: image.width,
            height: image.height,
            rotationDegrees: rotation,
            imageFormat: 'bgra8888',
            bytesPerRow: image.planes.first.bytesPerRow,
          );
    }
  }

  Uint8List? _extractNv21Bytes(CameraImage image) {
    if (image.planes.isEmpty) return null;
    if (image.planes.length == 1) {
      return image.planes.first.bytes;
    }
    if (image.planes.length == 3) {
      final int width = image.width;
      final int height = image.height;
      final int ySize = width * height;
      final int uvSize = width * height ~/ 2;
      final Uint8List nv21 = Uint8List(ySize + uvSize);

      final yPlane = image.planes[0];
      int outIndex = 0;
      for (int row = 0; row < height; row++) {
        final rowStart = row * yPlane.bytesPerRow;
        nv21.setRange(outIndex, outIndex + width, yPlane.bytes, rowStart);
        outIndex += width;
      }

      final uPlane = image.planes[1];
      final vPlane = image.planes[2];
      final uvRowStride = uPlane.bytesPerRow;
      final uvPixelStride = uPlane.bytesPerPixel ?? 1;
      final uvHeight = height ~/ 2;
      final uvWidth = width ~/ 2;

      for (int row = 0; row < uvHeight; row++) {
        for (int col = 0; col < uvWidth; col++) {
          final uvIndex = row * uvRowStride + col * uvPixelStride;
          if (uvIndex < vPlane.bytes.length && uvIndex < uPlane.bytes.length) {
            nv21[outIndex++] = vPlane.bytes[uvIndex];
            nv21[outIndex++] = uPlane.bytes[uvIndex];
          }
        }
      }
      return nv21;
    }
    return null;
  }

  Future<void> _onCaptureAndAnalyze() async {
    if (_isCapturing) return;

    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) {
      await _onPickGallery();
      return;
    }

    if (mounted) {
      setState(() => _isCapturing = true);
    }

    try {
      if (controller.value.isStreamingImages) {
        await controller.stopImageStream();
      }
      final XFile captured = await controller.takePicture();
      await ref.read(scannerProvider.notifier).analyzeFrozenPhoto(captured.path);
    } catch (e) {
      log.w('Capture failed: $e');
    } finally {
      if (mounted) {
        setState(() => _isCapturing = false);
      }
    }
  }

  Future<void> _onResumeLive() async {
    ref.read(scannerProvider.notifier).resumeLivePreview();
    final controller = _cameraController;
    if (controller != null && controller.value.isInitialized) {
      if (widget.enableLiveCameraConversion &&
          !controller.value.isStreamingImages) {
        try {
          await controller.startImageStream(_onCameraFrame);
        } catch (_) {}
      }
    } else {
      await _initCamera();
    }
  }

  Future<void> _onPickGallery() async {
    try {
      final XFile? picked = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1600,
        maxHeight: 1600,
      );
      if (picked == null) return;

      final controller = _cameraController;
      if (controller != null && controller.value.isStreamingImages) {
        try {
          await controller.stopImageStream();
        } catch (_) {}
      }

      await ref.read(scannerProvider.notifier).analyzeFrozenPhoto(picked.path);
    } catch (e) {
      log.w('Gallery pick failed: $e');
    }
  }

  Future<void> _onToggleTorch() async {
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) return;
    try {
      final next = !_isTorchOn;
      await controller.setFlashMode(next ? FlashMode.torch : FlashMode.off);
      if (mounted) {
        setState(() => _isTorchOn = next);
      }
    } catch (e) {
      log.w('Flash toggle unsupported: $e');
    }
  }

  Future<void> _openSourceCurrencyPicker({
    required List<Currency> sortedCurrencies,
    required List<Currency> allCurrencies,
    required ScannerState scannerState,
  }) async {
    final notifier = ref.read(scannerProvider.notifier);
    notifier.setPausedForPicker(true);
    try {
      await showSourceCurrencyPickerSheet(
        context: context,
        pinnedCurrencies: sortedCurrencies,
        allCurrencies: allCurrencies,
        currentLockedSymbol: scannerState.lockedSourceCurrency,
        locationCurrencyCode: scannerState.locationCurrencyCode,
        onSelect: (symbol) => notifier.setLockedSourceCurrency(symbol),
      );
    } finally {
      notifier.setPausedForPicker(false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final scannerState = ref.watch(scannerProvider);
    final sortedCurrencies = ref.watch(sortedCurrenciesProvider);
    final allCurrencies = ref.watch(currenciesProvider).currencies;
    final settings = ref.watch(settingsNotifierProvider).value;

    final selectedSymbols = sortedCurrencies.map((e) => e.symbol).toList();
    final activeSourceCurrency =
        scannerState.effectiveSourceCurrency(selectedSymbols);

    // Fixed bottom sheet height ensures the camera viewport above NEVER resizes or jumps.
    final screenHeight = MediaQuery.sizeOf(context).height;
    final bottomPadding = MediaQuery.paddingOf(context).bottom;
    final fixedSheetHeight =
        (screenHeight * 0.39).clamp(268.0, 344.0) + bottomPadding;

    void onPickSourceCurrency() => _openSourceCurrencyPicker(
          sortedCurrencies: sortedCurrencies,
          allCurrencies: allCurrencies,
          scannerState: scannerState,
        );

    return Scaffold(
      backgroundColor: Colors.black,
      body: Column(
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                _buildViewport(l10n, scannerState),
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: ScannerTopBar(
                    activeSourceCurrency: activeSourceCurrency,
                    isSourceLocked: scannerState.lockedSourceCurrency != null,
                    hasLocationCurrency:
                        scannerState.locationCurrencyCode != null,
                    isFrozen: scannerState.isFrozen,
                    isTorchOn: _isTorchOn,
                    hasTorch: _cameraController != null &&
                        _cameraController!.value.isInitialized,
                    onBack: () {
                      ref.read(scannerProvider.notifier).resumeLivePreview();
                      Navigator.of(context).maybePop();
                    },
                    onPickSourceCurrency: onPickSourceCurrency,
                    onToggleTorch: _onToggleTorch,
                    onPickGallery: _onPickGallery,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            height: fixedSheetHeight,
            child: ConvertedPricesSheet(
              scannerState: scannerState,
              activeSourceCurrency: activeSourceCurrency,
              sortedCurrencies: sortedCurrencies,
              allCurrencies: allCurrencies,
              roundingDecimals: settings?.roundingDecimals ?? 2,
              showFlags: settings?.showCountryFlags ?? true,
              enableLiveCameraConversion: widget.enableLiveCameraConversion,
              isCapturing: _isCapturing,
              onPickSourceCurrency: onPickSourceCurrency,
              onCaptureFreeze: _onCaptureAndAnalyze,
              onResumeLive: _onResumeLive,
              onSelectItem: (id) =>
                  ref.read(scannerProvider.notifier).selectItem(id),
              onToggleThousandsShorthand: (id) => ref
                  .read(scannerProvider.notifier)
                  .toggleThousandsShorthand(id),
              onUseInConverter: (sourceSymbol, exactAmount) {
                ref
                    .read(currencyInputsListViewModelProvider.notifier)
                    .applyScannedPrice(sourceSymbol, exactAmount);
                ref.read(scannerProvider.notifier).resumeLivePreview();
                Navigator.of(context).maybePop();
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildViewport(AppLocalizations l10n, ScannerState scannerState) {
    final overlay = PriceBoundingOverlay(
      items: scannerState.scanResult.items,
      selectedItemId: scannerState.selectedItem?.id,
      showCenterReticle: widget.enableLiveCameraConversion &&
          !scannerState.isFrozen &&
          !_cameraUnavailableOrDenied,
      dimReticle: scannerState.scanResult.items.isNotEmpty,
      onSelectItem: (id) => ref.read(scannerProvider.notifier).selectItem(id),
    );

    if (scannerState.isFrozen && scannerState.frozenImagePath != null) {
      final imgW = scannerState.scanResult.imageWidth;
      final imgH = scannerState.scanResult.imageHeight;
      final hasDimensions = imgW > 1 && imgH > 1;
      final photoWidget = Stack(
        fit: StackFit.expand,
        children: [
          Image.file(
            File(scannerState.frozenImagePath!),
            fit: BoxFit.contain,
          ),
          if (scannerState.scanResult.items.isNotEmpty) overlay,
        ],
      );
      return Center(
        child: hasDimensions
            ? AspectRatio(
                aspectRatio: imgW / imgH,
                child: photoWidget,
              )
            : photoWidget,
      );
    }

    if (_isInitializingCamera) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFF00E083)),
      );
    }

    final controller = _cameraController;
    if (_cameraUnavailableOrDenied ||
        controller == null ||
        !controller.value.isInitialized) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.no_photography_outlined,
              color: Colors.white60,
              size: 56,
            ),
            const SizedBox(height: 16),
            Text(
              l10n.cameraPermissionRequired,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 15),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              key: const Key('scanner_fallback_gallery_button'),
              onPressed: _onPickGallery,
              icon: const Icon(Icons.photo_library_outlined),
              label: Text(l10n.pickFromGallery),
            ),
          ],
        ),
      );
    }

    // Place PriceBoundingOverlay directly inside CameraPreview so normalized
    // OCR coordinates match the camera texture aspect ratio 1:1.
    return Center(
      child: CameraPreview(
        controller,
        child: overlay,
      ),
    );
  }
}
