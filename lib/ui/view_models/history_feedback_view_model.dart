import '../../engine/stimulus_ledger_engine.dart';
import '../../engine/training_status_engine.dart';
import '../../models/session_log.dart';
import '../../models/session_type.dart';
import '../../models/stimulus_ledger.dart';
import '../../models/training_status.dart';
import '../../models/training_targets.dart';

enum MuscleTargetBandState { belowMinimum, inBand, aboveMaximum }

enum CardioTargetState { met, deficit, notNeeded }

class MuscleTargetRowModel {
  final MajorMuscleGroup muscle;
  final String label;
  final double effectiveSets7d;
  final double effectiveSets28d;
  final double weeklyEquivalent28d;
  final MuscleTargetBandState bandState7d;
  final MuscleTargetBandState bandState28d;

  const MuscleTargetRowModel({
    required this.muscle,
    required this.label,
    required this.effectiveSets7d,
    required this.effectiveSets28d,
    required this.weeklyEquivalent28d,
    required this.bandState7d,
    required this.bandState28d,
  });
}

class CardioTargetRowModel {
  final AerobicTargetKind target;
  final String label;
  final int rollingWindowDays;
  final int completedExposures;
  final int targetExposures;
  final int exposureDeficit;
  final int completedDistinctDays;
  final int targetDistinctDays;
  final int distinctDayDeficit;
  final bool applicable;

  const CardioTargetRowModel({
    required this.target,
    required this.label,
    required this.rollingWindowDays,
    required this.completedExposures,
    required this.targetExposures,
    required this.exposureDeficit,
    this.completedDistinctDays = 0,
    this.targetDistinctDays = 0,
    this.distinctDayDeficit = 0,
    this.applicable = true,
  });

  bool get met => exposureDeficit == 0 && distinctDayDeficit == 0;
  bool get hasActiveDeficit => applicable && !met;
  CardioTargetState get state => !applicable
      ? CardioTargetState.notNeeded
      : met
          ? CardioTargetState.met
          : CardioTargetState.deficit;
}

/// Pure, display-ready projection of the personal hypertrophy and cardio
/// targets. It does not make or alter recommendations.
class HistoryFeedbackViewModel {
  final List<MuscleTargetRowModel> muscles;
  final List<CardioTargetRowModel> cardio;

  HistoryFeedbackViewModel({
    required List<MuscleTargetRowModel> muscles,
    required List<CardioTargetRowModel> cardio,
  })  : muscles = List<MuscleTargetRowModel>.unmodifiable(muscles),
        cardio = List<CardioTargetRowModel>.unmodifiable(cardio);

  factory HistoryFeedbackViewModel.fromStatus({
    required TrainingTargets targets,
    required StimulusLedgerSnapshot ledger,
    required TrainingStatus status,
  }) {
    final statusByTarget = {
      for (final value in status.aerobic) value.target: value,
    };

    final muscles = [
      for (final muscle in MajorMuscleGroup.values)
        _muscleRow(
          muscle: muscle,
          ledger: ledger,
          targetBand: targets.hypertrophyTargetBands[muscle]!,
        ),
    ];

    CardioTargetRowModel cardioRow(
      AerobicTargetKind target,
      String label, {
      bool applicable = true,
    }) {
      final value = statusByTarget[target]!;
      return CardioTargetRowModel(
        target: target,
        label: label,
        rollingWindowDays: value.rollingWindowDays,
        completedExposures: value.completedExposures,
        targetExposures: value.targetExposures,
        exposureDeficit: value.exposureDeficit,
        completedDistinctDays: value.completedDistinctDays,
        targetDistinctDays: value.targetDistinctDays,
        distinctDayDeficit: value.distinctDayDeficit,
        applicable: applicable,
      );
    }

    final rawFourByFourRow = cardioRow(
      AerobicTargetKind.norwegian4x4Anchor,
      'Norwegian 4×4 anchor',
    );
    final rawRehitFallbackRow = cardioRow(
      AerobicTargetKind.rehitSeparateDayFallback,
      'REHIT fallback',
    );

    // The weekly high-intensity target is disjunctive: a 4×4 is preferred,
    // while two qualifying REHIT days are its temporary fallback. Keep both
    // protocol counts untouched, but do not present the preferred protocol as
    // actively due after its fallback has already covered the weekly target.
    // If both happen to be complete, the 4×4 remains the anchor and the
    // fallback is correctly shown as unnecessary.
    final fourByFourRow = cardioRow(
      AerobicTargetKind.norwegian4x4Anchor,
      'Norwegian 4×4 anchor',
      applicable: rawFourByFourRow.met || !rawRehitFallbackRow.met,
    );
    final rehitFallbackRow = cardioRow(
      AerobicTargetKind.rehitSeparateDayFallback,
      'REHIT fallback',
      applicable: !rawFourByFourRow.met,
    );

    return HistoryFeedbackViewModel(
      muscles: muscles,
      cardio: [
        fourByFourRow,
        rehitFallbackRow,
        cardioRow(
          AerobicTargetKind.longBaseExposure,
          '${targets.baseLongExposureMinutes}m base exposure',
        ),
        cardioRow(
          AerobicTargetKind.shortBaseExposure,
          '${targets.baseShortExposureMinutes.join('/')}m base exposure',
        ),
      ],
    );
  }

  /// Convenience constructor for pure tests and other read-only consumers.
  /// Legacy logs without structured cardio completion are normalized by the
  /// same adapter used by the app.
  factory HistoryFeedbackViewModel.fromLogs({
    required Iterable<SessionLog> logs,
    required DateTime asOf,
    TrainingTargets? targets,
  }) {
    final effectiveTargets = targets ?? TrainingTargets();
    final ledger = const StimulusLedgerEngine().buildFromSessionLogs(
      logs: logs,
      asOf: asOf,
    );
    final status = const TrainingStatusEngine().build(
      targets: effectiveTargets,
      ledger: ledger,
    );
    return HistoryFeedbackViewModel.fromStatus(
      targets: effectiveTargets,
      ledger: ledger,
      status: status,
    );
  }

  MuscleTargetRowModel muscle(MajorMuscleGroup value) =>
      muscles.firstWhere((row) => row.muscle == value);

  CardioTargetRowModel cardioTarget(AerobicTargetKind value) =>
      cardio.firstWhere((row) => row.target == value);

  static MuscleTargetRowModel _muscleRow({
    required MajorMuscleGroup muscle,
    required StimulusLedgerSnapshot ledger,
    required EffectiveSetTargetBand targetBand,
  }) {
    final sevenDaySets = ledger.muscle(muscle).effectiveSets7d;
    final twentyEightDaySets = ledger.muscle(muscle).effectiveSets28d;
    return MuscleTargetRowModel(
      muscle: muscle,
      label: _muscleLabel(muscle),
      effectiveSets7d: sevenDaySets,
      effectiveSets28d: twentyEightDaySets,
      weeklyEquivalent28d: twentyEightDaySets / 4,
      bandState7d: _bandState(
        sevenDaySets,
        targetBand.minimumForWindow(7),
        targetBand.maximumForWindow(7),
      ),
      bandState28d: _bandState(
        twentyEightDaySets,
        targetBand.minimumForWindow(28),
        targetBand.maximumForWindow(28),
      ),
    );
  }

  static MuscleTargetBandState _bandState(
    double completed,
    double minimum,
    double maximum,
  ) =>
      completed < minimum
          ? MuscleTargetBandState.belowMinimum
          : completed > maximum
              ? MuscleTargetBandState.aboveMaximum
              : MuscleTargetBandState.inBand;

  static String _muscleLabel(MajorMuscleGroup value) => switch (value) {
        MajorMuscleGroup.quads => 'Quads',
        MajorMuscleGroup.glutes => 'Glutes',
        MajorMuscleGroup.hamstrings => 'Hamstrings',
        MajorMuscleGroup.chest => 'Chest',
        MajorMuscleGroup.back => 'Back',
        MajorMuscleGroup.delts => 'Delts',
        MajorMuscleGroup.biceps => 'Biceps',
        MajorMuscleGroup.triceps => 'Triceps',
        MajorMuscleGroup.coreGrip => 'Core/grip',
      };
}

/// Display-ready dose for one History session row.
///
/// Strength sessions retain their set completion. Cardio-only sessions use
/// the structured protocol completion when available, and legacy rows state
/// only the coarse duration that was actually persisted.
String historySessionDoseSummary(SessionLog log) {
  final completion = log.cardioCompletion;
  switch (log.templateId) {
    case SessionTypeId.s3:
      if (completion == null) return _legacyCardioDose(log);
      return '${completion.completedWorkIntervals} '
          '${completion.completedWorkIntervals == 1 ? 'work interval' : 'work intervals'} · '
          '${_cardioDuration(completion.completedWorkSeconds)} work · '
          '${_cardioDuration(completion.completedDurationSeconds)} total';
    case SessionTypeId.s6:
      if (completion == null) return _legacyCardioDose(log);
      return '${_cardioDuration(completion.completedDurationSeconds)} continuous';
    case SessionTypeId.s7:
      if (completion == null) return _legacyCardioDose(log);
      return '${completion.completedWorkIntervals} '
          '${completion.completedWorkIntervals == 1 ? 'sprint' : 'sprints'} · '
          '${_cardioDuration(completion.completedWorkSeconds)} work · '
          '${_cardioDuration(completion.completedDurationSeconds)} total';
    case SessionTypeId.s1:
    case SessionTypeId.s2:
    case SessionTypeId.s4:
    case SessionTypeId.s5:
      return '${log.completedWorkSets}/${log.plannedWorkSets} sets';
  }
}

String _legacyCardioDose(SessionLog log) =>
    '${log.durationMinutes} min logged · legacy cardio details unavailable';

String _cardioDuration(int seconds) {
  final minutes = seconds ~/ 60;
  final remainder = seconds.remainder(60).toString().padLeft(2, '0');
  return '$minutes:$remainder';
}
