import 'package:flutter/widgets.dart';

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

/// Optional logger that prints navigation events with emoji.
class AdScreenRouteLogger extends NavigatorObserver {
  @override
  void didPush(Route route, Route? previousRoute) {
    debugPrint('[AdScreen~Router] ➡️ PUSH: ${route.settings.name} '
        '(from: ${previousRoute?.settings.name})');
  }

  @override
  void didPop(Route route, Route? previousRoute) {
    debugPrint('[AdScreen~Router] ⬅️ POP: ${route.settings.name} '
        '(back to: ${previousRoute?.settings.name})');
  }

  @override
  void didRemove(Route route, Route? previousRoute) {
    debugPrint('[AdScreen~Router] 🗑️ REMOVE: ${route.settings.name}');
  }

  @override
  void didReplace({Route? newRoute, Route? oldRoute}) {
    debugPrint('[AdScreen~Router] 🔄 REPLACE: ${oldRoute?.settings.name} '
        '→ ${newRoute?.settings.name}');
  }
}
