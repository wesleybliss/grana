import 'package:dio/dio.dart';
import 'package:spot_di/spot_di.dart';

import 'package:grana/db/repos/currencies_repo.dart';
import 'package:grana/domain/io/i_settings.dart';
import 'package:grana/domain/io/net/dio_client.dart';
import 'package:grana/domain/io/net/i_dio_client.dart';
import 'package:grana/domain/io/repos/i_currencies_repo.dart';
import 'package:grana/domain/io/services/currencies_service.dart';
import 'package:grana/domain/io/services/i_currencies_service.dart';
import 'package:grana/domain/io/services/i_price_scanner_service.dart';
import 'package:grana/io/price_scanner_service.dart';
import 'package:grana/io/settings.dart';

abstract class SpotModule {
  static void registerDependencies() {
    Spot.init((factory, single) {
      // Globals
      single<ISettings, Settings>((get) => Settings());

      // Networking
      single<Dio, Dio>((get) => Dio());
      single<IDioClient, DioClient>((get) => DioClient());

      // Repositories
      factory<ICurrenciesRepo, CurrenciesRepo>((get) => CurrenciesRepo());

      // Services
      single<ICurrenciesService, CurrenciesService>(
        (get) => CurrenciesService(get<IDioClient>()),
      );
      single<IPriceScannerService, PriceScannerService>(
        (get) => PriceScannerService(),
      );
    });
  }
}

abstract class TestSpotModule extends SpotModule {
  static void registerDependencies() {
    Spot.init((factory, single) {});
  }
}
