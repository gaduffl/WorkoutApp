import '../models/lower_back_recovery.dart';
import '../models/session_type.dart';
import '../models/user_settings.dart';

/// Which kinds of stationary cycling may be planned right now. The manual
/// "Pause stationary cycling" switch closes everything; otherwise Back
/// rebuild's stepped bike return opens Zone 2 rides, then 4×4, then REHIT
/// (with finishers and nudges). Walking Zone 2 is never cycling.
class CyclingAccess {
  final bool zone2Ride;
  final bool fourByFour;
  final bool rehit;

  const CyclingAccess({
    required this.zone2Ride,
    required this.fourByFour,
    required this.rehit,
  });

  static const none = CyclingAccess(
    zone2Ride: false,
    fourByFour: false,
    rehit: false,
  );

  factory CyclingAccess.fromSettings(UserSettings settings) {
    if (settings.stationaryBikePaused) return none;
    final step = settings.lowerBackRecovery.bikeReturnStep;
    return CyclingAccess(
      zone2Ride: step.index >= BikeReturnStep.zone2Ride.index,
      fourByFour: step.index >= BikeReturnStep.fourByFour.index,
      rehit: step == BikeReturnStep.complete,
    );
  }

  bool get any => zone2Ride || fourByFour || rehit;

  /// Whether a cardio session type may be planned. S6 is always available
  /// because it falls back to an uphill walk. S3 below its 35-minute window
  /// is only reachable as the REHIT preset.
  bool allowsSession(SessionTypeId id, {required int slotMinutes}) =>
      switch (id) {
        SessionTypeId.s3 => slotMinutes >= 35 ? fourByFour : rehit,
        SessionTypeId.s7 => rehit,
        _ => true,
      };
}
