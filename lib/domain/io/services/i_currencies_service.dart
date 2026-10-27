import 'package:grana/domain/io/net/i_dio_client.dart';
import 'package:grana/domain/models/currency_response.dart';
import 'package:grana/utils/logger.dart';
import 'package:flutter/foundation.dart';

abstract class ICurrenciesService {
  @protected
  abstract final Logger log;

  @protected
  abstract final IDioClient dio;

  Future<CurrencyResponse?> fetchCurrencies();
}
