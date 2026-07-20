import 'cardio_protocol.dart';
import 'training_targets.dart';

/// One completed strength set, already resolved to its muscle contribution.
///
/// This normalized boundary keeps aggregation independent from persistence and
/// from the app's current persisted session representation.
class MuscleStimulusEvent {
  final String sourceId;
  final DateTime performedAt;
  final Map<MajorMuscleGroup, double> effectiveSets;

  MuscleStimulusEvent({
    required this.sourceId,
    required this.performedAt,
    required Map<MajorMuscleGroup, double> effectiveSets,
  }) : effectiveSets = Map<MajorMuscleGroup, double>.unmodifiable(
          effectiveSets,
        );
}

/// A completed, protocol-specific aerobic exposure.
///
/// Protocols intentionally remain separate. In particular, a REHIT exposure
/// is not recorded as Norwegian 4x4 or base aerobic work.
class AerobicStimulusEvent {
  final String sourceId;
  final CardioProtocolType protocol;
  final DateTime performedAt;
  final int durationMinutes;

  const AerobicStimulusEvent({
    required this.sourceId,
    required this.protocol,
    required this.performedAt,
    required this.durationMinutes,
  }) : assert(durationMinutes >= 0);
}

class MuscleStimulusStatus {
  final MajorMuscleGroup muscle;
  final double effectiveSets7d;
  final double effectiveSets28d;
  final int? daysSinceLastStimulus;

  const MuscleStimulusStatus({
    required this.muscle,
    required this.effectiveSets7d,
    required this.effectiveSets28d,
    required this.daysSinceLastStimulus,
  });

  double effectiveSetsForWindow(int days) => switch (days) {
        7 => effectiveSets7d,
        28 => effectiveSets28d,
        _ => throw ArgumentError.value(
            days,
            'days',
            'The stimulus ledger stores only 7-day and 28-day windows',
          ),
      };
}

class AerobicProtocolStatus {
  final CardioProtocolType protocol;
  final int sessions7d;
  final int sessions28d;
  final int separateDays7d;
  final int separateDays28d;
  final int durationMinutes7d;
  final int durationMinutes28d;
  final int? daysSinceLastStimulus;
  final List<int> sessionDurations7d;
  final List<int> sessionDurations28d;

  AerobicProtocolStatus({
    required this.protocol,
    required this.sessions7d,
    required this.sessions28d,
    required this.separateDays7d,
    required this.separateDays28d,
    required this.durationMinutes7d,
    required this.durationMinutes28d,
    required this.daysSinceLastStimulus,
    required List<int> sessionDurations7d,
    required List<int> sessionDurations28d,
  })  : sessionDurations7d = List<int>.unmodifiable(sessionDurations7d),
        sessionDurations28d = List<int>.unmodifiable(sessionDurations28d);

  int sessionsForWindow(int days) => switch (days) {
        7 => sessions7d,
        28 => sessions28d,
        _ => throw ArgumentError.value(
            days,
            'days',
            'The stimulus ledger stores only 7-day and 28-day windows',
          ),
      };

  int separateDaysForWindow(int days) => switch (days) {
        7 => separateDays7d,
        28 => separateDays28d,
        _ => throw ArgumentError.value(
            days,
            'days',
            'The stimulus ledger stores only 7-day and 28-day windows',
          ),
      };

  int durationMinutesForWindow(int days) => switch (days) {
        7 => durationMinutes7d,
        28 => durationMinutes28d,
        _ => throw ArgumentError.value(
            days,
            'days',
            'The stimulus ledger stores only 7-day and 28-day windows',
          ),
      };

  List<int> sessionDurationsForWindow(int days) => switch (days) {
        7 => sessionDurations7d,
        28 => sessionDurations28d,
        _ => throw ArgumentError.value(
            days,
            'days',
            'The stimulus ledger stores only 7-day and 28-day windows',
          ),
      };

  int sessionsAtLeastMinutes7d(int thresholdMinutes) =>
      sessionsAtLeastMinutes(7, thresholdMinutes);

  int sessionsAtLeastMinutes28d(int thresholdMinutes) =>
      sessionsAtLeastMinutes(28, thresholdMinutes);

  int sessionsAtLeastMinutes(int days, int thresholdMinutes) {
    if (thresholdMinutes <= 0) {
      throw ArgumentError.value(
        thresholdMinutes,
        'thresholdMinutes',
        'Must be positive',
      );
    }
    return sessionDurationsForWindow(days)
        .where((duration) => duration >= thresholdMinutes)
        .length;
  }
}

class StimulusLedgerSnapshot {
  final DateTime asOf;
  final Map<MajorMuscleGroup, MuscleStimulusStatus> muscles;
  final Map<CardioProtocolType, AerobicProtocolStatus> aerobic;
  final int highIntensityDistinctDays7d;
  final int highIntensityDistinctDays28d;

  StimulusLedgerSnapshot({
    required this.asOf,
    required Map<MajorMuscleGroup, MuscleStimulusStatus> muscles,
    required Map<CardioProtocolType, AerobicProtocolStatus> aerobic,
    this.highIntensityDistinctDays7d = 0,
    this.highIntensityDistinctDays28d = 0,
  })  : muscles = Map<MajorMuscleGroup, MuscleStimulusStatus>.unmodifiable(
          muscles,
        ),
        aerobic = Map<CardioProtocolType, AerobicProtocolStatus>.unmodifiable(
          aerobic,
        ),
        assert(highIntensityDistinctDays7d >= 0),
        assert(highIntensityDistinctDays28d >= 0);

  MuscleStimulusStatus muscle(MajorMuscleGroup value) => muscles[value]!;

  AerobicProtocolStatus protocol(CardioProtocolType value) => aerobic[value]!;

  int get separateDayRehitCount7d =>
      protocol(CardioProtocolType.rehit).separateDays7d;

  int get separateDayRehitCount28d =>
      protocol(CardioProtocolType.rehit).separateDays28d;
}
