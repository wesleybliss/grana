import 'package:grana/domain/constants/keys.dart';
import 'package:grana/domain/constants/routing.dart';
import 'package:grana/domain/constants/strings.dart';

import 'integers.dart';

abstract class Constants {
  static final keys = ConstantsKeys();
  static final routing = RoutingConstants();
  static final strings = ConstantsStrings();
  static final integers = ConstantsIntegers();
}
