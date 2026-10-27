class ConstantsStrings {
  // final appName = 'Simple Currency';
  final appName = 'Grana';
  final appSlug = 'simple-currency';
  final useLocalApiServer = false;

  String get baseUrl {
    const bool isProduction = bool.fromEnvironment('dart.vm.product');

    if (isProduction || !useLocalApiServer) {
      return 'https://simple-currency-cron.vercel.app/api';
    } else {
      return 'http://localhost:3002/api';
    }
  }
}
