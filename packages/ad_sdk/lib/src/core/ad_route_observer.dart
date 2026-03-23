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
class AdScreenRouteLogger extends NavigatorObserver {
  static const _tag = 'AdScreen~Router';

  @override
  void didPush(Route route, Route? previousRoute) {
    SafeLogger.d(_tag, '➡️ PUSH: ${route.settings.name} '
        '(from: ${previousRoute?.settings.name})');
  }

  @override
  void didPop(Route route, Route? previousRoute) {
    SafeLogger.d(_tag, '⬅️ POP: ${route.settings.name} '
        '(back to: ${previousRoute?.settings.name})');
  }

  @override
  void didRemove(Route route, Route? previousRoute) {
    SafeLogger.d(_tag, '🗑️ REMOVE: ${route.settings.name}');
  }

  @override
  void didReplace({Route? newRoute, Route? oldRoute}) {
    SafeLogger.d(_tag, '🔄 REPLACE: ${oldRoute?.settings.name} '
        '→ ${newRoute?.settings.name}');
  }
}
