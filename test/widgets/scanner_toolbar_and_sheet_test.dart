import 'package:fluro/fluro.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:grana/config/application.dart';
import 'package:grana/config/feature_flags.dart';
import 'package:grana/config/routing/routes.dart';
import 'package:grana/db/database.dart';
import 'package:grana/domain/di/providers/scanner/scanner_provider.dart';
import 'package:grana/domain/models/scanned_price.dart';
import 'package:grana/l10n/app_localizations.dart';
import 'package:grana/ui/screens/scanner/widgets/converted_prices_sheet.dart';
import 'package:grana/ui/widgets/toolbar.dart';

void main() {
  setUpAll(() {
    if (!Application.isInitialized) {
      final router = FluroRouter();
      Routes.configureRoutes(router);
      Application.router = router;
    }
  });

  testWidgets(
    'Toolbar places Camera action button as the left-most trailing icon in Standard flavor',
    (tester) async {
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              appBar: Toolbar(title: 'Grana'),
              body: SizedBox.shrink(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final appBar = tester.widget<AppBar>(find.byType(AppBar));
      expect(appBar.actions, isNotNull);
      expect(appBar.actions!.length, 4);

      final cameraFinder = find.byKey(const Key('toolbar_camera_button'));
      final favoritesFinder = find.byIcon(Icons.favorite);
      expect(cameraFinder, findsOneWidget);
      expect(favoritesFinder, findsOneWidget);

      // Verify Camera button is strictly to the left of Favorites icon
      final cameraDx = tester.getCenter(cameraFinder).dx;
      final favoritesDx = tester.getCenter(favoritesFinder).dx;
      expect(cameraDx, lessThan(favoritesDx));
    },
  );

  testWidgets(
    'ConvertedPricesSheet renders conversions without text labels, exposes source currency picker, and triggers converter handoff',
    (tester) async {
      const currencies = [
        Currency(
          id: 1,
          symbol: 'USD',
          name: 'US Dollar',
          rate: 1.0,
          selected: true,
          order: 0,
        ),
        Currency(
          id: 2,
          symbol: 'EUR',
          name: 'Euro',
          rate: 0.90,
          selected: true,
          order: 1,
        ),
      ];

      const scannerState = ScannerState(
        isFrozen: true,
        locationCurrencyCode: 'DOP',
        scanResult: ScanAnalysisResult(
          inferredCurrencyCode: 'DOP',
          tierUsed: AiScannerTier.onDeviceOcr,
          items: [
            ScannedPriceItem(
              id: 'item_1',
              rawText: 'RD\$600',
              itemLabel: 'Should Not Render',
              normalizedAmount: 600.0,
              detectedCurrencyCode: 'DOP',
            ),
          ],
        ),
        selectedItemId: 'item_1',
      );

      final allCurrencies = [
        ...currencies,
        const Currency(
          id: 3,
          symbol: 'DOP',
          name: 'Dominican Peso',
          rate: 60.0,
          selected: false,
          order: 2,
        ),
      ];

      String? handedOffCurrency;
      double? handedOffAmount;
      bool pickerOpened = false;

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SizedBox(
              height: 320,
              child: ConvertedPricesSheet(
                scannerState: scannerState,
                activeSourceCurrency: 'DOP',
                sortedCurrencies: currencies,
                allCurrencies: allCurrencies,
                roundingDecimals: 2,
                showFlags: false,
                onPickSourceCurrency: () => pickerOpened = true,
                onCaptureFreeze: () {},
                onResumeLive: () {},
                onSelectItem: (_) {},
                onToggleThousandsShorthand: (_) {},
                onUseInConverter: (symbol, amount) {
                  handedOffCurrency = symbol;
                  handedOffAmount = amount;
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 600 DOP at 60 DOP/USD = 10 USD and 9 EUR; itemLabel is never displayed
      expect(find.text('Should Not Render'), findsNothing);
      expect(find.text('600 DOP'), findsOneWidget);
      expect(find.text('10'), findsOneWidget);
      expect(find.text('9'), findsOneWidget);

      // Source currency picker button is directly accessible inside the sheet
      await tester.tap(
        find.byKey(const Key('scanner_sheet_source_currency_button')),
      );
      await tester.pump();
      expect(pickerOpened, isTrue);

      await tester.tap(find.byKey(const Key('scanner_use_in_converter_button')));
      await tester.pump();

      expect(handedOffCurrency, 'DOP');
      expect(handedOffAmount, 600.0);
    },
  );

  test('Live camera conversion feature flag defaults to off', () {
    expect(FeatureFlags.enableLiveCameraConversion, isFalse);
  });

  testWidgets(
    'ConvertedPricesSheet in still-capture mode shows Take Photo CTA before capture and clean 2-decimal conversions after capture',
    (tester) async {
      const currencies = [
        Currency(
          id: 1,
          symbol: 'USD',
          name: 'US Dollar',
          rate: 1.0,
          selected: true,
          order: 0,
        ),
        Currency(
          id: 2,
          symbol: 'EUR',
          name: 'Euro',
          rate: 0.91,
          selected: true,
          order: 1,
        ),
      ];
      final allCurrencies = [
        ...currencies,
        const Currency(
          id: 3,
          symbol: 'DOP',
          name: 'Dominican Peso',
          rate: 60.27,
          selected: false,
          order: 2,
        ),
      ];

      bool captured = false;

      // 1. Before capture (viewfinder state with live camera disabled)
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SizedBox(
              height: 320,
              child: ConvertedPricesSheet(
                scannerState: const ScannerState(
                  isFrozen: false,
                  locationCurrencyCode: 'DOP',
                ),
                activeSourceCurrency: 'DOP',
                sortedCurrencies: currencies,
                allCurrencies: allCurrencies,
                roundingDecimals: 4,
                showFlags: false,
                enableLiveCameraConversion: false,
                onPickSourceCurrency: () {},
                onCaptureFreeze: () => captured = true,
                onResumeLive: () {},
                onSelectItem: (_) {},
                onToggleThousandsShorthand: (_) {},
                onUseInConverter: (_, _) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('scanner_capture_button')), findsOneWidget);
      expect(find.byKey(const Key('scanner_freeze_button')), findsNothing);
      expect(
        find.byKey(const Key('scanner_use_in_converter_button')),
        findsNothing,
      );

      await tester.tap(find.byKey(const Key('scanner_capture_button')));
      await tester.pump();
      expect(captured, isTrue);

      // 2. After still capture: 1350 DOP -> 22.40 USD (2 decimals even with roundingDecimals=4)
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SizedBox(
              height: 320,
              child: ConvertedPricesSheet(
                scannerState: const ScannerState(
                  isFrozen: true,
                  locationCurrencyCode: 'DOP',
                  scanResult: ScanAnalysisResult(
                    inferredCurrencyCode: 'DOP',
                    tierUsed: AiScannerTier.onDeviceOcr,
                    items: [
                      ScannedPriceItem(
                        id: 'item_1',
                        rawText: '\$1.350',
                        normalizedAmount: 1350.0,
                        detectedCurrencyCode: 'DOP',
                      ),
                    ],
                  ),
                  selectedItemId: 'item_1',
                ),
                activeSourceCurrency: 'DOP',
                sortedCurrencies: currencies,
                allCurrencies: allCurrencies,
                roundingDecimals: 4,
                showFlags: false,
                enableLiveCameraConversion: false,
                onPickSourceCurrency: () {},
                onCaptureFreeze: () {},
                onResumeLive: () {},
                onSelectItem: (_) {},
                onToggleThousandsShorthand: (_) {},
                onUseInConverter: (_, _) {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Retake'), findsOneWidget);
      expect(find.text('22.40'), findsOneWidget);
      expect(find.text('20.38'), findsOneWidget);
      expect(find.text('22.3992'), findsNothing);
      expect(
        find.byKey(const Key('scanner_use_in_converter_button')),
        findsOneWidget,
      );
    },
  );
}
