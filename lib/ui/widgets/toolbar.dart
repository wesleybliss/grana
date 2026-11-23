import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:grana/config/application.dart';
import 'package:grana/config/flavor.dart';
import 'package:grana/config/routing/routes.dart';
import 'package:grana/l10n/app_localizations.dart';

import 'toolbar_theme_toggle.dart';

class Toolbar extends ConsumerWidget implements PreferredSizeWidget {
  final String title;
  final double height;
  final bool showActions;
  final bool showCameraAction;
  final bool allowBackNavigation;

  const Toolbar({
    super.key,
    required this.title,
    this.height = 56.0, // Default height for AppBar
    this.showActions = true,
    this.showCameraAction = true,
    this.allowBackNavigation = false,
  });

  @override
  Size get preferredSize => Size.fromHeight(height);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final List<Widget> actions = !showActions
        ? []
        : [
            if (showCameraAction && !FlavorConfig.isFossBuild)
              IconButton(
                key: const Key('toolbar_camera_button'),
                icon: const Icon(Icons.photo_camera_outlined),
                tooltip: l10n.scanPrices,
                onPressed: () {
                  Application.router.navigateTo(
                    context,
                    Routes.scanner,
                    rootNavigator: true,
                  );
                },
              ),
            IconButton(
              icon: const Icon(Icons.favorite), // Heart icon for favorites
              tooltip: l10n.favorites,
              onPressed: () {
                Application.router.navigateTo(context, Routes.currencies);
              },
            ),
            const ToolbarThemeToggle(),
            IconButton(
              icon: const Icon(Icons.settings), // Settings icon
              tooltip: l10n.settings,
              onPressed: () {
                Application.router.navigateTo(context, Routes.settings);
              },
            ),
          ];

    return AppBar(
      title: Text(
        title,
        style: const TextStyle(fontFamily: 'BricolageGrotesque'),
      ),
      actions: actions,
      automaticallyImplyLeading: allowBackNavigation, // Prevent back button
    );
  }
}
