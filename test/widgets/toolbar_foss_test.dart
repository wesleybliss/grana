import 'package:fluro/fluro.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:grana/config/application.dart';
import 'package:grana/config/flavor.dart';
import 'package:grana/config/routing/routes.dart';
import 'package:grana/l10n/app_localizations.dart';
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
    'Toolbar camera visibility respects FlavorConfig.isFossBuild',
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

      final cameraButton = find.byKey(const Key('toolbar_camera_button'));
      if (FlavorConfig.isFossBuild) {
        expect(cameraButton, findsNothing);
      } else {
        expect(cameraButton, findsOneWidget);
      }
    },
  );
}
