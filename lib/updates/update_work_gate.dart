import 'package:flutter/material.dart';

import '../state/app_controller.dart';

/// Every route over Home may hold an input, workout timer or pending save.
/// Its closure rechecks a waiting update without a new server request.
class UpdateRouteChanges extends NavigatorObserver with ChangeNotifier {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      notifyListeners();

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      notifyListeners();

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      notifyListeners();

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) =>
      notifyListeners();
}

bool appHasUpdateWorkInProgress(
  AppController controller,
  NavigatorState? navigator,
) => controller.updateWorkInFlight || (navigator?.canPop() ?? false);
