/// The three cardio stimuli tracked independently by the training model.
enum CardioProtocolType { norwegian4x4, zone2Base, rehit }

/// Stable identity and human-readable name for a cardio protocol.
class CardioProtocol {
  final CardioProtocolType type;
  final String name;

  const CardioProtocol({required this.type, required this.name});

  static const norwegian4x4 = CardioProtocol(
    type: CardioProtocolType.norwegian4x4,
    name: 'CAROL 4×4 Norwegian Zone 5 Intervals',
  );
  static const zone2Base = CardioProtocol(
    type: CardioProtocolType.zone2Base,
    name: 'Zone 2 / base aerobic',
  );
  static const rehit = CardioProtocol(
    type: CardioProtocolType.rehit,
    name: 'CAROL REHIT Intense',
  );
}

/// Exact dose the app prescribed for a cardio session.
///
/// Work and recovery seconds are totals across the stated interval counts.
/// [plannedDurationSeconds] is the total bike-guided preset or continuous
/// duration. CAROL-owned warm-up, transitions, and cooldown are deliberately
/// not decomposed into app-authored segments.
class CardioPrescription {
  final CardioProtocol protocol;
  final int plannedWorkIntervals;
  final int plannedWorkSeconds;
  final int plannedRecoveryIntervals;
  final int plannedRecoverySeconds;
  final int plannedDurationSeconds;
  final double? targetHeartRateMinBpm;
  final double? targetHeartRateMaxBpm;
  final double? targetRpeMin;
  final double? targetRpeMax;

  const CardioPrescription({
    required this.protocol,
    required this.plannedWorkIntervals,
    required this.plannedWorkSeconds,
    required this.plannedRecoveryIntervals,
    required this.plannedRecoverySeconds,
    required this.plannedDurationSeconds,
    this.targetHeartRateMinBpm,
    this.targetHeartRateMaxBpm,
    this.targetRpeMin,
    this.targetRpeMax,
  })  : assert(plannedWorkIntervals >= 0),
        assert(plannedWorkSeconds >= 0),
        assert(plannedRecoveryIntervals >= 0),
        assert(plannedRecoverySeconds >= 0),
        assert(plannedDurationSeconds >=
            plannedWorkSeconds + plannedRecoverySeconds),
        assert(targetHeartRateMinBpm == null || targetHeartRateMinBpm > 0),
        assert(targetHeartRateMaxBpm == null || targetHeartRateMaxBpm > 0),
        assert(targetHeartRateMinBpm == null ||
            targetHeartRateMaxBpm == null ||
            targetHeartRateMaxBpm >= targetHeartRateMinBpm),
        assert(targetRpeMin == null ||
            (targetRpeMin >= 0 && targetRpeMin <= 10)),
        assert(targetRpeMax == null ||
            (targetRpeMax >= 0 && targetRpeMax <= 10)),
        assert(targetRpeMin == null ||
            targetRpeMax == null ||
            targetRpeMax >= targetRpeMin);
}

/// Exact dose completed during a cardio session.
class CardioCompletion {
  final CardioProtocol protocol;
  final int completedWorkIntervals;
  final int completedWorkSeconds;
  final int completedRecoveryIntervals;
  final int completedRecoverySeconds;
  final int completedDurationSeconds;
  final double? averageHeartRateBpm;
  final double? peakHeartRateBpm;
  final double? rpe;

  const CardioCompletion({
    required this.protocol,
    required this.completedWorkIntervals,
    required this.completedWorkSeconds,
    required this.completedRecoveryIntervals,
    required this.completedRecoverySeconds,
    required this.completedDurationSeconds,
    this.averageHeartRateBpm,
    this.peakHeartRateBpm,
    this.rpe,
  })  : assert(completedWorkIntervals >= 0),
        assert(completedWorkSeconds >= 0),
        assert(completedRecoveryIntervals >= 0),
        assert(completedRecoverySeconds >= 0),
        assert(completedDurationSeconds >=
            completedWorkSeconds + completedRecoverySeconds),
        assert(averageHeartRateBpm == null || averageHeartRateBpm > 0),
        assert(peakHeartRateBpm == null || peakHeartRateBpm > 0),
        assert(rpe == null || (rpe >= 0 && rpe <= 10));

  /// Whether this attempt delivered the minimum dose that earns training
  /// credit. The stimuli stay intentionally separate: a short REHIT never
  /// stands in for 4x4 or base work, and a sub-30-minute easy ride is still
  /// useful recovery without becoming a qualifying base exposure.
  bool get meetsCreditableDose => switch (protocol.type) {
        CardioProtocolType.norwegian4x4 =>
          completedWorkIntervals == 4 && completedWorkSeconds >= 960,
        CardioProtocolType.zone2Base =>
          completedWorkIntervals == 1 &&
              completedWorkSeconds >= 1800 &&
              completedDurationSeconds >= 1800,
        CardioProtocolType.rehit =>
          completedWorkIntervals == 2 && completedWorkSeconds >= 40,
      };

  /// Whether the recorded dose completed the exact plan that was shown.
  ///
  /// This is deliberately separate from [meetsCreditableDose]. For example,
  /// a prescribed 20-minute S6 recovery ride is complete as prescribed even
  /// though it is below the 30-minute threshold for base-aerobic credit. In
  /// the other direction, 30 minutes of a prescribed 35-minute S6 earns base
  /// credit but is still only a partial completion of that plan.
  ///
  /// Heart-rate and RPE targets are coaching ranges rather than required
  /// completion fields, so adherence here compares the prescribed dose only.
  bool completesPrescription(CardioPrescription prescription) =>
      protocol.type == prescription.protocol.type &&
      completedWorkIntervals >= prescription.plannedWorkIntervals &&
      completedWorkSeconds >= prescription.plannedWorkSeconds &&
      completedRecoveryIntervals >= prescription.plannedRecoveryIntervals &&
      completedRecoverySeconds >= prescription.plannedRecoverySeconds &&
      completedDurationSeconds >= prescription.plannedDurationSeconds;
}
