import 'package:flutter/services.dart';

/// Android bridge for the short tone that marks the end of a logger
/// countdown. Missing platform support is deliberately non-fatal: tests and
/// other platforms simply end the countdown silently.
class TimerBeep {
  static const _channel = MethodChannel('morningcoach/timer_beep');

  const TimerBeep._();

  static Future<void> play() async {
    try {
      await _channel.invokeMethod<void>('beep');
    } on MissingPluginException {
      // Platform has no bridge; the countdown ends without a tone.
    } on PlatformException {
      // A tone must never interrupt logging a workout.
    }
  }
}
