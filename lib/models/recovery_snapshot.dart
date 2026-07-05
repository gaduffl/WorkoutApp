/// §2.4 / §4 RecoverySnapshot (daily, from Oura or manual entry).
/// Any field left null is treated as "missing" for §4.2 renormalization.
class RecoverySnapshot {
  final DateTime date;
  final double? hrvRmssd;
  final double? restingHr;
  final int? sleepScore;
  final int? ouraReadinessScore;
  final bool manualEntry;

  const RecoverySnapshot({
    required this.date,
    this.hrvRmssd,
    this.restingHr,
    this.sleepScore,
    this.ouraReadinessScore,
    this.manualEntry = true,
  });
}
