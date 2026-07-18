import '../models/cardio_protocol.dart';
import '../models/session_type.dart';

/// Pure protocol construction, entry conversion, and runtime validation.
///
/// The UI and controller both use this class so a malformed or mismatched
/// completion cannot earn credit through a different call path.
class CardioEngine {
  const CardioEngine();

  CardioProtocol protocolFor(SessionTypeId sessionId) => switch (sessionId) {
        SessionTypeId.s3 => CardioProtocol.norwegian4x4,
        SessionTypeId.s6 => CardioProtocol.zone2Base,
        SessionTypeId.s7 => CardioProtocol.rehit,
        _ => throw ArgumentError.value(
            sessionId,
            'sessionId',
            'Must identify a cardio-only session',
          ),
      };

  /// Resolves a plan's executable/display prescription. S3 and S7 are fixed
  /// CAROL presets, so stale persisted metadata from older app versions must
  /// never reintroduce app-authored timing. S6 remains duration-scaled and
  /// therefore preserves the exact prescription stored with its plan.
  CardioPrescription resolvePrescription({
    required SessionTypeId sessionId,
    required CardioPrescription? persistedPrescription,
    required int durationMinutes,
    required double heartRateMaxBpm,
  }) {
    if (sessionId == SessionTypeId.s6 &&
        persistedPrescription != null &&
        persistedPrescription.protocol.type ==
            CardioProtocolType.zone2Base) {
      return persistedPrescription;
    }
    return prescriptionFor(
      sessionId: sessionId,
      durationMinutes: durationMinutes,
      heartRateMaxBpm: heartRateMaxBpm,
    );
  }

  CardioPrescription prescriptionFor({
    required SessionTypeId sessionId,
    required int durationMinutes,
    required double heartRateMaxBpm,
  }) {
    if (durationMinutes <= 0) {
      throw ArgumentError.value(
        durationMinutes,
        'durationMinutes',
        'Must be positive',
      );
    }
    if (!heartRateMaxBpm.isFinite || heartRateMaxBpm <= 0) {
      throw ArgumentError.value(
        heartRateMaxBpm,
        'heartRateMaxBpm',
        'Must be positive and finite',
      );
    }

    return switch (sessionId) {
      SessionTypeId.s3 => CardioPrescription(
          protocol: CardioProtocol.norwegian4x4,
          plannedWorkIntervals: 4,
          plannedWorkSeconds: 960,
          plannedRecoveryIntervals: 3,
          plannedRecoverySeconds: 540,
          plannedDurationSeconds: 30 * 60,
          targetHeartRateMinBpm: heartRateMaxBpm * 0.85,
          targetHeartRateMaxBpm: heartRateMaxBpm * 0.95,
          targetRpeMin: 8,
          targetRpeMax: 9,
        ),
      SessionTypeId.s6 => CardioPrescription(
          protocol: CardioProtocol.zone2Base,
          plannedWorkIntervals: 1,
          plannedWorkSeconds: durationMinutes * 60,
          plannedRecoveryIntervals: 0,
          plannedRecoverySeconds: 0,
          plannedDurationSeconds: durationMinutes * 60,
          targetHeartRateMinBpm: heartRateMaxBpm * 0.65,
          targetHeartRateMaxBpm: heartRateMaxBpm * 0.75,
          targetRpeMin: 3,
          targetRpeMax: 4,
        ),
      SessionTypeId.s7 => const CardioPrescription(
          protocol: CardioProtocol.rehit,
          plannedWorkIntervals: 2,
          plannedWorkSeconds: 40,
          // CAROL owns the preset's warm-up, between-sprint recovery, and
          // cooldown. The app records only the two completed work intervals
          // plus the total duration displayed by the bike.
          plannedRecoveryIntervals: 0,
          plannedRecoverySeconds: 0,
          plannedDurationSeconds: 8 * 60 + 40,
          targetRpeMin: 9,
          targetRpeMax: 10,
        ),
      _ => throw ArgumentError.value(
          sessionId,
          'sessionId',
          'Must identify a cardio-only session',
        ),
    };
  }

  /// Converts the compact UI form into the exact structured dose. Interval
  /// work/recovery seconds come from the prescription; the user records how
  /// many intervals and total minutes they actually completed.
  CardioCompletion completionFromEntry({
    required CardioPrescription prescription,
    required int completedWorkIntervals,
    required int completedDurationMinutes,
    double? averageHeartRateBpm,
    double? peakHeartRateBpm,
    double? rpe,
    double? fitnessScore,
    double? peakPowerWatts,
  }) {
    if (completedDurationMinutes <= 0 || completedDurationMinutes > 24 * 60) {
      throw ArgumentError.value(
        completedDurationMinutes,
        'completedDurationMinutes',
        'Must be between 1 minute and 24 hours',
      );
    }
    return completionFromElapsedSeconds(
      prescription: prescription,
      completedWorkIntervals: completedWorkIntervals,
      completedDurationSeconds: completedDurationMinutes * 60,
      averageHeartRateBpm: averageHeartRateBpm,
      peakHeartRateBpm: peakHeartRateBpm,
      rpe: rpe,
      fitnessScore: fitnessScore,
      peakPowerWatts: peakPowerWatts,
    );
  }

  /// Exact-duration counterpart used for CAROL's bike-displayed `M:SS`
  /// timing. The minute-based API above remains available for Zone 2,
  /// compatibility, and callers that do not need second precision.
  CardioCompletion completionFromElapsedSeconds({
    required CardioPrescription prescription,
    required int completedWorkIntervals,
    required int completedDurationSeconds,
    double? averageHeartRateBpm,
    double? peakHeartRateBpm,
    double? rpe,
    double? fitnessScore,
    double? peakPowerWatts,
  }) {
    if (completedWorkIntervals <= 0 ||
        completedWorkIntervals > prescription.plannedWorkIntervals) {
      throw ArgumentError.value(
        completedWorkIntervals,
        'completedWorkIntervals',
        'Enter 1-${prescription.plannedWorkIntervals}',
      );
    }
    if (completedDurationSeconds <= 0 ||
        completedDurationSeconds > 24 * 60 * 60) {
      throw ArgumentError.value(
        completedDurationSeconds,
        'completedDurationSeconds',
        'Must be between 1 second and 24 hours',
      );
    }

    late final int completedWorkSeconds;
    late final int completedRecoveryIntervals;
    late final int completedRecoverySeconds;

    switch (prescription.protocol.type) {
      case CardioProtocolType.norwegian4x4:
      case CardioProtocolType.rehit:
        completedWorkSeconds = _leadingDistributedSeconds(
          prescription.plannedWorkSeconds,
          prescription.plannedWorkIntervals,
          completedWorkIntervals,
        );
        completedRecoveryIntervals = (completedWorkIntervals - 1)
            .clamp(0, prescription.plannedRecoveryIntervals)
            .toInt();
        completedRecoverySeconds = _leadingDistributedSeconds(
          prescription.plannedRecoverySeconds,
          prescription.plannedRecoveryIntervals,
          completedRecoveryIntervals,
        );
      case CardioProtocolType.zone2Base:
        completedWorkSeconds = completedDurationSeconds;
        completedRecoveryIntervals = 0;
        completedRecoverySeconds = 0;
    }

    if (completedWorkSeconds + completedRecoverySeconds >
        completedDurationSeconds) {
      throw ArgumentError(
        'Duration is shorter than the completed work and recovery intervals.',
      );
    }
    final completion = CardioCompletion(
      protocol: prescription.protocol,
      completedWorkIntervals: completedWorkIntervals,
      completedWorkSeconds: completedWorkSeconds,
      completedRecoveryIntervals: completedRecoveryIntervals,
      completedRecoverySeconds: completedRecoverySeconds,
      completedDurationSeconds: completedDurationSeconds,
      averageHeartRateBpm: averageHeartRateBpm,
      peakHeartRateBpm: peakHeartRateBpm,
      rpe: rpe,
      fitnessScore: fitnessScore,
      peakPowerWatts: peakPowerWatts,
    );
    validateCompletion(
      prescription: prescription,
      completion: completion,
    );
    return completion;
  }

  void validateCompletion({
    required CardioPrescription prescription,
    required CardioCompletion completion,
  }) {
    if (completion.protocol.type != prescription.protocol.type) {
      throw ArgumentError(
        'Completion protocol does not match the prescribed protocol.',
      );
    }
    if (completion.completedWorkIntervals <= 0 ||
        completion.completedWorkIntervals > prescription.plannedWorkIntervals) {
      throw ArgumentError.value(
        completion.completedWorkIntervals,
        'completedWorkIntervals',
        'Must be within the prescribed interval count',
      );
    }
    if (completion.completedWorkSeconds <= 0 ||
        completion.completedWorkSeconds > prescription.plannedWorkSeconds) {
      throw ArgumentError.value(
        completion.completedWorkSeconds,
        'completedWorkSeconds',
        'Must be within the prescribed work dose',
      );
    }
    if (completion.completedRecoveryIntervals < 0 ||
        completion.completedRecoveryIntervals >
            prescription.plannedRecoveryIntervals) {
      throw ArgumentError.value(
        completion.completedRecoveryIntervals,
        'completedRecoveryIntervals',
        'Must be within the prescribed recovery count',
      );
    }
    if (completion.completedRecoverySeconds < 0 ||
        completion.completedRecoverySeconds >
            prescription.plannedRecoverySeconds) {
      throw ArgumentError.value(
        completion.completedRecoverySeconds,
        'completedRecoverySeconds',
        'Must be within the prescribed recovery dose',
      );
    }
    if (completion.completedDurationSeconds <= 0 ||
        completion.completedDurationSeconds > 24 * 60 * 60 ||
        completion.completedDurationSeconds <
            completion.completedWorkSeconds +
                completion.completedRecoverySeconds) {
      throw ArgumentError.value(
        completion.completedDurationSeconds,
        'completedDurationSeconds',
        'Must be positive and long enough for the recorded work',
      );
    }
    _validateHeartRate(
      completion.averageHeartRateBpm,
      'averageHeartRateBpm',
    );
    _validateHeartRate(completion.peakHeartRateBpm, 'peakHeartRateBpm');
    if (completion.averageHeartRateBpm != null &&
        completion.peakHeartRateBpm != null &&
        completion.averageHeartRateBpm! > completion.peakHeartRateBpm!) {
      throw ArgumentError('Average heart rate cannot exceed peak heart rate.');
    }
    if (completion.rpe != null &&
        (!completion.rpe!.isFinite ||
            completion.rpe! < 0 ||
            completion.rpe! > 10)) {
      throw ArgumentError.value(
        completion.rpe,
        'rpe',
        'Must be between 0 and 10',
      );
    }
    _validateNonNegativeFinite(
      completion.fitnessScore,
      'fitnessScore',
    );
    _validatePositiveFinite(
      completion.peakPowerWatts,
      'peakPowerWatts',
    );
  }

  void validateSessionMatch({
    required SessionTypeId sessionId,
    required CardioPrescription prescription,
    required CardioCompletion completion,
  }) {
    final expected = protocolFor(sessionId).type;
    if (prescription.protocol.type != expected ||
        completion.protocol.type != expected) {
      throw ArgumentError(
        'Session, prescription, and completion protocols must match.',
      );
    }
    validateCompletion(
      prescription: prescription,
      completion: completion,
    );
  }

  void _validateHeartRate(double? value, String name) {
    if (value != null && (!value.isFinite || value < 30 || value > 260)) {
      throw ArgumentError.value(
        value,
        name,
        'Must be between 30 and 260 bpm',
      );
    }
  }

  void _validateNonNegativeFinite(double? value, String name) {
    if (value != null && (!value.isFinite || value < 0)) {
      throw ArgumentError.value(value, name, 'Must be non-negative and finite');
    }
  }

  void _validatePositiveFinite(double? value, String name) {
    if (value != null && (!value.isFinite || value <= 0)) {
      throw ArgumentError.value(value, name, 'Must be positive and finite');
    }
  }
}

int _leadingDistributedSeconds(int totalSeconds, int count, int completed) {
  if (count <= 0 || completed <= 0) return 0;
  final boundedCompleted = completed.clamp(0, count).toInt();
  final base = totalSeconds ~/ count;
  final remainder = totalSeconds % count;
  return base * boundedCompleted +
      (boundedCompleted < remainder ? boundedCompleted : remainder);
}
