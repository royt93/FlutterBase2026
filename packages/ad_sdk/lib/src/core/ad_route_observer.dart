import 'package:flutter/material.dart';

import '../utils/safe_logger.dart';

/// Drop-in replacement for [showModalBottomSheet] that is always visible to
/// [AdScreenRouteLogger.isDialogOnTop].
///
/// Round-28 audit finding: [showModalBottomSheet] defaults to
/// `useRootNavigator: false` — unlike [showDialog], which defaults to
/// `true` — so it pushes onto whichever `Navigator` owns [context]. In an
/// app with nested Navigators (bottom-nav tabs, a `go_router` `ShellRoute`
/// branch, ...) that is usually a *nested* Navigator, not the root one
/// `AdScreenRouteLogger` is registered on per the integration contract. The
/// sheet then goes untracked and a resumed App Open ad can show on top of
/// it. This helper always forces `useRootNavigator: true` so the sheet is
/// pushed on the observed root Navigator no matter which nested Navigator's
/// [context] it is called from.
Future<T?> showAdSafeModalBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  Color? backgroundColor,
  ShapeBorder? shape,
  bool isScrollControlled = false,
  bool isDismissible = true,
  bool enableDrag = true,
  bool useSafeArea = false,
  BoxConstraints? constraints,
  RouteSettings? routeSettings,
}) {
  return showModalBottomSheet<T>(
    context: context,
    builder: builder,
    backgroundColor: backgroundColor,
    shape: shape,
    isScrollControlled: isScrollControlled,
    isDismissible: isDismissible,
    enableDrag: enableDrag,
    useSafeArea: useSafeArea,
    constraints: constraints,
    routeSettings: routeSettings,
    useRootNavigator: true,
  );
}

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
  static int _popupDepthField = 0;
  static int get _popupDepth => _popupDepthField;
  static set _popupDepth(int value) {
    _popupDepthField = value;
    isDialogOnTopNotifier.value = value > 0;
  }

  /// T75 — reactive mirror of [isDialogOnTop], so [AdManager.fullscreenBusy]
  /// (and any other listener) can react to it without polling.
  static final ValueNotifier<bool> isDialogOnTopNotifier =
      ValueNotifier<bool>(false);

  /// `true` when at least one dialog/popup route is currently presented.
  static bool get isDialogOnTop => _popupDepth > 0;

  /// Reset the popup counter.
  ///
  /// Round-38 audit fix (NITPICK) — this docstring used to say "Called by
  /// [AdManager.destroy]", but round 37 deliberately REMOVED that call (a
  /// live dialog/popup route survives `destroy()`, same as a live UMP form;
  /// zeroing this here made `isDialogOnTop` lie `false` while a dialog was
  /// still genuinely on screen, letting an App Open ad stack on top of it —
  /// see `ad_manager.dart`'s own comment at that removal site). Left in
  /// place only for test isolation across a shared Dart isolate and crash
  /// recovery paths that don't go through `destroy()`. A stale docstring
  /// here risked a future maintainer re-adding the exact call round 37
  /// removed, reintroducing that bug.
  static void resetState() {
    _popupDepth = 0;
    _navigationEventsObserved = 0;
  }

  /// T98 — count of navigation callbacks (`didPush`/`didPop`/`didRemove`/
  /// `didReplace`) seen since the last [resetState]. An instance of this
  /// class only ever receives these if it was actually added to some
  /// `Navigator`'s `observers` — so a non-zero count is evidence the host
  /// app really did register `AdScreenRouteLogger()` in
  /// `navigatorObservers`, used by `AdManager.runIntegrationSelfCheck`'s
  /// "Route observer wired" check.
  static int _navigationEventsObserved = 0;
  static int get navigationEventsObserved => _navigationEventsObserved;

  @override
  void didPush(Route route, Route? previousRoute) {
    _navigationEventsObserved++;
    if (route is PopupRoute) _popupDepth++;
    SafeLogger.d(
        _tag,
        '➡️ PUSH: ${route.settings.name} '
        '(from: ${previousRoute?.settings.name}) popupDepth=$_popupDepth');
  }

  @override
  void didPop(Route route, Route? previousRoute) {
    _navigationEventsObserved++;
    if (route is PopupRoute && _popupDepth > 0) _popupDepth--;
    SafeLogger.d(
        _tag,
        '⬅️ POP: ${route.settings.name} '
        '(back to: ${previousRoute?.settings.name}) popupDepth=$_popupDepth');
  }

  @override
  void didRemove(Route route, Route? previousRoute) {
    _navigationEventsObserved++;
    if (route is PopupRoute && _popupDepth > 0) _popupDepth--;
    SafeLogger.d(
        _tag,
        '🗑️ REMOVE: ${route.settings.name} '
        'popupDepth=$_popupDepth');
  }

  @override
  void didReplace({Route? newRoute, Route? oldRoute}) {
    _navigationEventsObserved++;
    if (oldRoute is PopupRoute && _popupDepth > 0) _popupDepth--;
    if (newRoute is PopupRoute) _popupDepth++;
    SafeLogger.d(
        _tag,
        '🔄 REPLACE: ${oldRoute?.settings.name} '
        '→ ${newRoute?.settings.name} popupDepth=$_popupDepth');
  }
}
