import '../models/cardio_protocol.dart';
import '../models/exercise_state.dart';
import '../models/floor_category.dart';
import '../models/movement_pattern.dart';
import '../models/pain.dart';
import '../models/session_log.dart';
import '../models/session_type.dart';

/// Shared safety facts for every high-intensity entry point.
///
/// Target surplus remains an explicit user choice. These facts are hard
/// safety constraints: a primary, forced, restored, finisher, or later-day
/// high-intensity session must not bypass them.
class HighIntensitySafetyStatus {
  final bool intensityRecoveryActive;
  final bool contraindicatingPainActive;
  final bool painEscalationActive;
  final bool deloadActive;
  final bool travelUnavailable;

  const HighIntensitySafetyStatus({
    required this.intensityRecoveryActive,
    required this.contraindicatingPainActive,
    required this.painEscalationActive,
    required this.deloadActive,
    required this.travelUnavailable,
  });

  bool get blocked =>
      intensityRecoveryActive ||
      contraindicatingPainActive ||
      painEscalationActive ||
      deloadActive ||
      travelUnavailable;
}

/// Pure recovery-safety classification for recent high-intensity work.
///
/// This is intentionally more conservative than stimulus qualification: a
/// partial interval can create recovery load even when it is too incomplete to
/// earn the Norwegian 4x4/REHIT target credit tracked by StimulusLedgerEngine.
class IntensityRecoveryPolicy {
  const IntensityRecoveryPolicy();

  static const _cyclingContraindicatingRegions = {
    BodyRegion.lowerBack,
    BodyRegion.hip,
    BodyRegion.kneeLeft,
    BodyRegion.kneeRight,
  };

  /// Evaluates the common recovery, pain, deload, and equipment gates used
  /// by primary S3/S7 selection and optional REHIT entry points.
  HighIntensitySafetyStatus evaluateHighIntensitySafety({
    required Iterable<SessionLog> logs,
    required DateTime asOf,
    required Iterable<PainFlag> checkInPain,
    required Iterable<ExerciseState> exerciseStates,
    bool automaticGlobalDeload = false,
    bool travelMode = false,
  }) {
    final states = exerciseStates.toList();
    final frozenStates = states
        .where((state) => state.painFrozen)
        .toList();
    final contraindicatingPainActive = checkInPain.any(
          (flag) => _cyclingContraindicatingRegions.contains(flag.region),
        ) ||
        frozenStates.any(
          (state) =>
              _cyclingContraindicatingRegions.contains(state.painRegion) ||
              (state.painRegion == null &&
                  (state.pattern == MovementPattern.squat ||
                      state.pattern == MovementPattern.hinge)),
        );
    final painEscalationActive = checkInPain.any(
          (flag) => _isEscalatedPain(
            severity: flag.severity,
            flaggedDate: flag.flaggedDate,
            tags: flag.tags,
            asOf: asOf,
          ),
        ) ||
        frozenStates.any(
          (state) => _isEscalatedPain(
            severity: state.painSeverity,
            flaggedDate: state.painFlaggedDate,
            tags: state.painTags,
            asOf: asOf,
          ),
        );
    final deloadActive = automaticGlobalDeload ||
        states.any(
          (state) =>
              state.status == ExerciseStatus.deload ||
              state.deloadSessionsRemaining > 0,
        );

    return HighIntensitySafetyStatus(
      intensityRecoveryActive: hasRelevantIntensityInInclusiveWindow(
        logs,
        asOf: asOf,
      ),
      contraindicatingPainActive: contraindicatingPainActive,
      painEscalationActive: painEscalationActive,
      deloadActive: deloadActive,
      travelUnavailable: travelMode,
    );
  }

  /// Conservative timestamp used only for rolling-hour recovery safety.
  ///
  /// A legacy row with calendar-date precision could have been completed at
  /// any time that day, so its guard ages from the end of that local day.
  /// Stimulus-ledger timing continues to use [SessionLog.completedAt].
  DateTime recoveryWindowCompletedAt(SessionLog log) {
    if (log.completedAtPrecision == CompletionTimePrecision.exact) {
      return log.completedAt;
    }
    final day = log.date;
    return DateTime(day.year, day.month, day.day + 1)
        .subtract(const Duration(microseconds: 1));
  }

  bool isRecoveryRelevant(SessionLog log) {
    // The strength-session completion ratio must not erase a finisher that was
    // actually performed.
    if (log.templateId == SessionTypeId.s2 &&
        log.rehitFinisherCompleted) {
      return true;
    }

    final structured = log.cardioCompletion;
    if (structured != null) {
      final isHighIntensity =
          structured.protocol.type == CardioProtocolType.norwegian4x4 ||
              structured.protocol.type == CardioProtocolType.rehit;
      return isHighIntensity &&
          (structured.completedWorkIntervals > 0 ||
              structured.completedWorkSeconds > 0);
    }

    if (!log.countsAs.contains(FloorCategory.intensity) ||
        log.durationMinutes <= 0) {
      return false;
    }

    // Before structured cardio logging, an intensity category plus a
    // plausible partial dose was the only persisted evidence. One 4-minute
    // 4x4 work interval or a one-minute REHIT attempt is enough recovery load
    // to guard, even though neither earns target credit. S2's intensity
    // category was conditional on doing its finisher, so it remains useful
    // fail-safe evidence when the later finisher boolean is absent. Reject
    // impossible/very short rows rather than treating a stray category as
    // recovery load.
    return switch (log.templateId) {
      SessionTypeId.s3 => log.durationMinutes >= 4,
      SessionTypeId.s7 => log.durationMinutes >= 1,
      SessionTypeId.s2 =>
        log.durationMinutes >=
            sessionTypes[SessionTypeId.s2]!.minDurationMin!,
      _ => false,
    };
  }

  bool hasRelevantIntensityInInclusiveWindow(
    Iterable<SessionLog> logs, {
    required DateTime asOf,
    Duration window = const Duration(hours: 48),
  }) {
    for (final log in logs) {
      if (!isRecoveryRelevant(log) || !_couldHaveOccurredBy(log, asOf)) {
        continue;
      }
      if (log.completedAtPrecision ==
              CompletionTimePrecision.dateOnlyInferred &&
          _isSameLocalDate(log.date, asOf)) {
        // The persisted row proves the workout happened sometime today even
        // though its conservative end-of-day recovery timestamp is later
        // than the current clock observation.
        return true;
      }
      final recoveryAt = recoveryWindowCompletedAt(log);
      if (recoveryAt.isAfter(asOf)) continue;
      if (asOf.difference(recoveryAt) <= window) return true;
    }
    return false;
  }

  bool _couldHaveOccurredBy(SessionLog log, DateTime asOf) {
    if (log.completedAtPrecision == CompletionTimePrecision.exact) {
      return !log.completedAt.isAfter(asOf);
    }
    return _localDateKey(log.date) <= _localDateKey(asOf);
  }

  int _localDateKey(DateTime value) =>
      value.year * 10000 + value.month * 100 + value.day;

  bool _isSameLocalDate(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  bool _isEscalatedPain({
    required PainSeverity? severity,
    required DateTime? flaggedDate,
    required Set<PainTag> tags,
    required DateTime asOf,
  }) {
    final hardTag = tags.intersection(const {
      PainTag.radiating,
      PainTag.numbness,
      PainTag.tingling,
      PainTag.weakness,
      PainTag.saddleNumbness,
      PainTag.bladderBowelChange,
    }).isNotEmpty;
    final persistentSharp = severity == PainSeverity.sharp &&
        flaggedDate != null &&
        asOf.difference(flaggedDate).inDays > 7;
    return hardTag || persistentSharp;
  }
}
