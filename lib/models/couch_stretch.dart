/// The optional left and right couch stretches: timed hip-flexor holds after
/// the strength warm-up. They are warm-up entries that never progress, earn
/// stimulus credit or advance a ladder.
class CouchStretch {
  const CouchStretch._();

  static const leftTrackKey = 'warmup:couch_stretch_left';
  static const rightTrackKey = 'warmup:couch_stretch_right';

  static const defaultHoldSeconds = 60;
  static const minHoldSeconds = 15;
  static const maxHoldSeconds = 300;

  /// The per-side holds Settings offers. A restored value outside this list
  /// is kept (within the bounds) and shown alongside them.
  static const holdOptionsSeconds = [30, 45, 60, 90, 120, 180];

  static bool isTrack(String trackKey) =>
      trackKey == leftTrackKey || trackKey == rightTrackKey;

  static int clampHoldSeconds(int seconds) =>
      seconds.clamp(minHoldSeconds, maxHoldSeconds).toInt();
}
