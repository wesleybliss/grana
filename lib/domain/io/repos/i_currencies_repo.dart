import 'package:grana/db/database.dart';
import 'package:grana/db/repos/repository.dart';

abstract class ICurrenciesRepo
    extends Repository<Currency, CurrenciesCompanion> {
  Future<List<Currency>> findAllOrderedByOrder();
}
