enum BoulderingEffort { easy, moderate, hard }

/// One manually recorded indoor/outdoor bouldering session.
///
/// This is deliberately separate from a MorningCoach session log: bouldering contributes
/// estimated muscle stimulus, but never completes a MorningCoach prescription,
/// advances its queue, or changes an exercise progression track.
class BoulderingLog {
  final String id;
  final DateTime date;
  final int durationMinutes;
  final BoulderingEffort effort;

  const BoulderingLog({
    required this.id,
    required this.date,
    required this.durationMinutes,
    required this.effort,
  }) : assert(durationMinutes > 0);
}
