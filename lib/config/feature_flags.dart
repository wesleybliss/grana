/// Feature flags controlling staged or experimental functionality.
///
/// Defaults can be overridden at build/run time via `--dart-define`, e.g.:
/// `flutter run --dart-define=ENABLE_LIVE_CAMERA_CONVERSION=true`
class FeatureFlags {
  /// Enables real-time OCR price detection over the live camera stream.
  ///
  /// When `false` (default), the scanner operates in still-capture mode:
  /// users frame a price or menu, take a photo (or pick one from the gallery),
  /// and convert the detected prices on the captured image.
  static const bool enableLiveCameraConversion = bool.fromEnvironment(
    'ENABLE_LIVE_CAMERA_CONVERSION',
    defaultValue: false,
  );
}
