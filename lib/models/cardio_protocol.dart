/// The three cardio stimuli tracked independently by the training model.
enum CardioProtocolType { norwegian4x4, zone2Base, rehit }

/// Stable identity and human-readable name for a cardio protocol.
class CardioProtocol {
  final CardioProtocolType type;
  final String name;

  const CardioProtocol({required this.type, required this.name});

  static const norwegian4x4 = CardioProtocol(
    type: CardioProtocolType.norwegian4x4,
    name: 'Norwegian 4x4',
  );
  static const zone2Base = CardioProtocol(
    type: CardioProtocolType.zone2Base,
    name: 'Zone 2 / base aerobic',
  );
  static const rehit = CardioProtocol(
    type: CardioProtocolType.rehit,
    name: 'REHIT',
  );
}

/// Exact dose the app prescribed for a cardio session.
///
/// Work and recovery seconds are totals across the stated interval counts.
/// [plannedDurationSeconds] also includes any protocol-owned preparation,
/// transitions, and cooldown.
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
}
