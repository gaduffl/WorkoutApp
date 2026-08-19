import 'package:flutter/services.dart';

/// Android screen-awake bridge used only while the workout logger is active.
/// Missing platform support is deliberately non-fatal (tests and future
/// platforms simply keep their normal display policy).
class ScreenAwake {
  static const _channel = MethodChannel('morningcoach/screen_awake');

  const ScreenAwake._();

  static Future<void> setEnabled(bool enabled) async {
    try {
      await _channel.invokeMethod<void>('setEnabled', enabled);
    } on MissingPluginException {
      // Platform has no bridge; retain its default display policy.
    } on PlatformException {
      // Screen policy must never prevent logging a workout.
    }
  }
}
