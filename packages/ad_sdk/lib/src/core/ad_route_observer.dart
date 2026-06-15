import 'package:flutter/widgets.dart';

import '../utils/safe_logger.dart';

/// Global RouteObserver for banner ad lifecycle management.
///
/// Register in your app's [navigatorObservers]:
/// ```dart
/// GetMaterialApp(
///   navigatorObservers: [adRouteObserver, AdScreenRouteLogger()],
/// )
/// ```
final RouteObserver<ModalRoute<void>> adRouteObserver =
    RouteObserver<ModalRoute<void>>();

/// Optional logger that records navigation events via [SafeLogger].
///
/// Besides logging, it tracks how many [PopupRoute]s (dialogs, bottom sheets,
/// Cupertino popups) are currently on the navigation stack. The ad SDK uses
/// [isDialogOnTop] to avoid showing a fullscreen App Open ad on top of a
/// modal — e.g. the consent dialog, a VIP redeem confirmation, or the SDK's
/// own loading buffer — which is both bad UX and an AdMob policy risk.
class AdScreenRouteLogger extends NavigatorObserver {
  static const _tag = 'AdScreen~Router';

  /// Number of [PopupRoute]s currently on the stack. Clamped at 0 so a stray
  /// pop/remove can never drive it negative and wedge the counter.
  static int _popupDepth = 0;

  /// `true` when at least one dialog/popup route is currently presented.
  static bool get isDialogOnTop => _popupDepth > 0;

  /// Reset the popup counter. Called by [AdManager.destroy] so a mid-dialog
  /// teardown (or hot restart) doesn't leave [isDialogOnTop] stuck true and
  /// permanently suppress App Open ads.
  static void resetState() => _popupDepth = 0;

  @override
  void didPush(Route route, Route? previousRoute) {
    if (route is PopupRoute) _popupDepth++;
    SafeLogger.d(_tag, '➡️ PUSH: ${route.settings.name} '
        '(from: ${previousRoute?.settings.name}) popupDepth=$_popupDepth');
  }

  @override
  void didPop(Route route, Route? previousRoute) {
    if (route is PopupRoute && _popupDepth > 0) _popupDepth--;
    SafeLogger.d(_tag, '⬅️ POP: ${route.settings.name} '
        '(back to: ${previousRoute?.settings.name}) popupDepth=$_popupDepth');
  }

  @override
  void didRemove(Route route, Route? previousRoute) {
    if (route is PopupRoute && _popupDepth > 0) _popupDepth--;
    SafeLogger.d(_tag, '🗑️ REMOVE: ${route.settings.name} '
        'popupDepth=$_popupDepth');
  }

  @override
  void didReplace({Route? newRoute, Route? oldRoute}) {
    if (oldRoute is PopupRoute && _popupDepth > 0) _popupDepth--;
    if (newRoute is PopupRoute) _popupDepth++;
    SafeLogger.d(_tag, '🔄 REPLACE: ${oldRoute?.settings.name} '
        '→ ${newRoute?.settings.name} popupDepth=$_popupDepth');
  }
}
