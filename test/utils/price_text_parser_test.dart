import 'package:flutter_test/flutter_test.dart';

import 'package:grana/db/database.dart';
import 'package:grana/domain/models/scanned_price.dart';
import 'package:grana/utils/currency_utils.dart';
import 'package:grana/utils/price_text_parser.dart';

void main() {
  group('PriceTextParser.parseRegionalNumber', () {
    test('parses US decimal and thousands separators', () {
      expect(PriceTextParser.parseRegionalNumber('14.50'), 14.50);
      expect(PriceTextParser.parseRegionalNumber('1,299.99'), 1299.99);
      expect(PriceTextParser.parseRegionalNumber('1,280'), 1280.0);
    });

    test('parses European comma decimals and dot thousands', () {
      expect(PriceTextParser.parseRegionalNumber('12,50'), 12.50);
      expect(PriceTextParser.parseRegionalNumber('1.299,50'), 1299.50);
      expect(PriceTextParser.parseRegionalNumber('1.250.000'), 1250000.0);
    });

    test('parses dot-thousands across non-inflated currencies (e.g. DOP \$1.350, \$1.300)', () {
      expect(
        PriceTextParser.parseRegionalNumber('1.350', currencyCode: 'DOP'),
        1350.0,
      );
      expect(
        PriceTextParser.parseRegionalNumber('1.300', currencyCode: 'DOP'),
        1300.0,
      );
      expect(
        PriceTextParser.parseRegionalNumber('2.450', currencyCode: 'EUR'),
        2450.0,
      );
      expect(
        PriceTextParser.parseRegionalNumber('18.750', currencyCode: 'USD'),
        18750.0,
      );
      expect(
        PriceTextParser.parseRegionalNumber('0.350', currencyCode: 'DOP'),
        0.35,
      );
      expect(
        PriceTextParser.parseRegionalNumber('1234.500', currencyCode: 'USD'),
        1234.5,
      );
    });

    test('preserves 3-decimal prices for 3-decimal currencies (KWD/BHD/OMR/JOD/TND/LYD)', () {
      expect(
        PriceTextParser.parseRegionalNumber('1.350', currencyCode: 'KWD'),
        1.35,
      );
      expect(
        PriceTextParser.parseRegionalNumber('2.750', currencyCode: 'BHD'),
        2.75,
      );
      expect(
        PriceTextParser.parseRegionalNumber('1,350', currencyCode: 'KWD'),
        1350.0,
      );
    });

    test('handles OCR comma/dot misreads like 1.350.00 and 1,350,00', () {
      expect(
        PriceTextParser.parseRegionalNumber('1.350.00', currencyCode: 'DOP'),
        1350.0,
      );
      expect(
        PriceTextParser.parseRegionalNumber('1.350.50', currencyCode: 'DOP'),
        1350.5,
      );
      expect(
        PriceTextParser.parseRegionalNumber('1,350,00', currencyCode: 'USD'),
        1350.0,
      );
    });

    test('parses inflated dot-thousands like COP 18.000 and 18.500', () {
      expect(
        PriceTextParser.parseRegionalNumber('18.000', currencyCode: 'COP'),
        18000.0,
      );
      expect(
        PriceTextParser.parseRegionalNumber('18.500', currencyCode: 'COP'),
        18500.0,
      );
    });

    test('reconciles AI amounts when LLM misreads dot-thousands as decimals', () {
      expect(
        PriceTextParser.reconcileAiAmount(
          rawText: '\$1.350',
          aiAmount: 1.35,
          currencyCode: 'DOP',
        ),
        1350.0,
      );
      expect(
        PriceTextParser.reconcileAiAmount(
          rawText: '\$1.300',
          aiAmount: 1.3,
          currencyCode: 'DOP',
        ),
        1300.0,
      );
      // Preserves intentional shorthand expansion (e.g. menu in thousands)
      expect(
        PriceTextParser.reconcileAiAmount(
          rawText: '18',
          aiAmount: 18000.0,
          currencyCode: 'COP',
          isShorthandMultiplied: true,
        ),
        18000.0,
      );
    });

    test('applies k/K thousands shorthand multiplier', () {
      expect(
        PriceTextParser.parseRegionalNumber('18', hasKMultiplier: true),
        18000.0,
      );
      expect(
        PriceTextParser.parseRegionalNumber('45.5', hasKMultiplier: true),
        45500.0,
      );
    });
  });

  group('PriceTextParser.parseOcrLines', () {
    test('extracts prices without text/dish labels and resolves unambiguous symbols', () {
      final result = PriceTextParser.parseOcrLines(
        const [
          OcrTextLine(
            text: 'Margherita Pizza ...... 14,50 €',
            boundingBox: NormalizedRect(
              left: 0.1,
              top: 0.2,
              width: 0.8,
              height: 0.08,
            ),
          ),
          OcrTextLine(
            text: 'Tiramisu 7,00 €',
            boundingBox: NormalizedRect(
              left: 0.1,
              top: 0.35,
              width: 0.6,
              height: 0.08,
            ),
          ),
        ],
        selectedCurrencies: const ['USD', 'EUR'],
      );

      expect(result.inferredCurrencyCode, 'EUR');
      expect(result.items.length, 2);
      expect(result.items[0].itemLabel, isNull);
      expect(result.items[0].normalizedAmount, 14.50);
      expect(result.items[0].detectedCurrencyCode, 'EUR');
      expect(result.items[1].itemLabel, isNull);
      expect(result.items[1].normalizedAmount, 7.00);
    });

    test('handles Swiss CHF .- without attaching text labels', () {
      final result = PriceTextParser.parseOcrLines(
        const [
          OcrTextLine(text: 'Zürcher Geschnetzeltes'),
          OcrTextLine(text: 'CHF 34.-'),
        ],
        selectedCurrencies: const ['USD'],
      );

      expect(result.inferredCurrencyCode, 'CHF');
      expect(result.items.length, 1);
      expect(result.items.first.itemLabel, isNull);
      expect(result.items.first.normalizedAmount, 34.0);
    });

    test('resolves RD\$ unambiguously to DOP even when COP is pinned', () {
      final result = PriceTextParser.parseOcrLines(
        const [
          OcrTextLine(text: 'RD\$ 450'),
          OcrTextLine(text: 'RD\$1,250.00'),
        ],
        selectedCurrencies: const ['COP', 'USD'],
      );

      expect(result.inferredCurrencyCode, 'DOP');
      expect(result.items.length, 2);
      expect(result.items[0].detectedCurrencyCode, 'DOP');
      expect(result.items[0].normalizedAmount, 450.0);
      expect(result.items[1].detectedCurrencyCode, 'DOP');
      expect(result.items[1].normalizedAmount, 1250.0);
    });

    test('uses locationCurrency (DOP) for \$ and dot-thousands instead of assuming COP', () {
      final result = PriceTextParser.parseOcrLines(
        const [
          OcrTextLine(text: '\$1.350'),
          OcrTextLine(text: '\$1.300'),
          OcrTextLine(text: 'Desde: \$850'),
        ],
        selectedCurrencies: const ['COP', 'EUR', 'USD'],
        locationCurrency: 'DOP',
      );

      expect(result.inferredCurrencyCode, 'DOP');
      expect(result.items.length, 3);
      expect(result.items[0].detectedCurrencyCode, 'DOP');
      expect(result.items[0].normalizedAmount, 1350.0);
      expect(result.items[1].detectedCurrencyCode, 'DOP');
      expect(result.items[1].normalizedAmount, 1300.0);
      expect(result.items[2].detectedCurrencyCode, 'DOP');
      expect(result.items[2].normalizedAmount, 850.0);
    });

    test('manual lockedSourceCurrency overrides locationCurrency and OCR symbols', () {
      final result = PriceTextParser.parseOcrLines(
        const [
          OcrTextLine(text: '\$25.00'),
        ],
        selectedCurrencies: const ['COP', 'USD'],
        locationCurrency: 'DOP',
        lockedSourceCurrency: 'USD',
      );

      expect(result.inferredCurrencyCode, 'USD');
      expect(result.items.single.detectedCurrencyCode, 'USD');
      expect(result.items.single.normalizedAmount, 25.0);
    });

    test('disambiguates COP dot-thousands when location is unknown and flags small inflated shorthand', () {
      final dotThousands = PriceTextParser.parseOcrLines(
        const [
          OcrTextLine(text: 'Bandeja Paisa \$28.000'),
        ],
        selectedCurrencies: const ['USD', 'COP'],
      );

      expect(dotThousands.inferredCurrencyCode, 'COP');
      expect(dotThousands.items.single.normalizedAmount, 28000.0);

      final smallLocked = PriceTextParser.parseOcrLines(
        const [
          OcrTextLine(text: 'Cold Brew 12'),
        ],
        selectedCurrencies: const ['USD', 'COP'],
        lockedSourceCurrency: 'COP',
      );

      expect(smallLocked.items.single.normalizedAmount, 12.0);
      expect(smallLocked.items.single.canToggleThousandsShorthand, isTrue);
    });

    test('rejects calories, volumes, percentages, times, phone numbers, years, and prose numbers', () {
      final result = PriceTextParser.parseOcrLines(
        const [
          OcrTextLine(text: '550 kcal'),
          OcrTextLine(text: '350 ml'),
          OcrTextLine(text: '500g'),
          OcrTextLine(text: '15%'),
          OcrTextLine(text: '10:30 AM'),
          OcrTextLine(text: '+1 800-555-0199'),
          OcrTextLine(text: 'Since 1998'),
          OcrTextLine(text: 'Menu 2026'),
          OcrTextLine(text: 'Abierto 24 horas al dia'),
          OcrTextLine(text: 'Calle 27 de Febrero'),
          OcrTextLine(text: 'Mesa #12'),
          OcrTextLine(text: 'Espresso \$3.75'),
        ],
        selectedCurrencies: const ['USD'],
      );

      expect(result.items.length, 1);
      expect(result.items.single.itemLabel, isNull);
      expect(result.items.single.normalizedAmount, 3.75);
    });
  });

  group('convertFromAnyCurrency', () {
    final allCurrencies = [
      const Currency(
        id: 1,
        symbol: 'USD',
        name: 'US Dollar',
        rate: 1.0,
        selected: true,
        order: 0,
      ),
      const Currency(
        id: 2,
        symbol: 'EUR',
        name: 'Euro',
        rate: 0.90,
        selected: true,
        order: 1,
      ),
      const Currency(
        id: 3,
        symbol: 'COP',
        name: 'Colombian Peso',
        rate: 4000.0,
        selected: true,
        order: 2,
      ),
      const Currency(
        id: 4,
        symbol: 'DOP',
        name: 'Dominican Peso',
        rate: 60.0,
        selected: false,
        order: 3,
      ),
    ];

    test('converts non-pinned currency (DOP) into pinned currencies accurately', () {
      final pinned = allCurrencies.where((c) => c.selected).toList();
      final res = convertFromAnyCurrency(
        sourceSymbol: 'DOP',
        amount: 600.0, // 10 USD
        targetCurrencies: pinned,
        allCurrencies: allCurrencies,
        roundingDecimals: 2,
      );

      expect(res['USD'], 10.0);
      expect(res['EUR'], 9.0);
      expect(res['COP'], 40000.0);
    });

    test('does NOT double-multiply COP scanned price by 1000', () {
      final pinned = allCurrencies.where((c) => c.selected).toList();
      final res = convertFromAnyCurrency(
        sourceSymbol: 'COP',
        amount: 20000.0, // Exact $20.000 COP = $5 USD
        targetCurrencies: pinned,
        allCurrencies: allCurrencies,
        roundingDecimals: 2,
      );

      expect(res['USD'], 5.0);
      expect(res['EUR'], 4.5);
      expect(res['COP'], 20000.0);
    });
  });
}
