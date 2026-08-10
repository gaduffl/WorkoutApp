import '../models/cardio_protocol.dart';
import '../models/floor_category.dart';
import '../models/movement_pattern.dart';
import '../models/session_log.dart';
import '../models/session_type.dart';
import '../models/set_log.dart';
import '../models/stimulus_ledger.dart';
import '../models/training_targets.dart';

/// A fixed exercise-to-muscle map for the app's deliberately small catalogue.
///
/// Named tracks are resolved before their underlying movement pattern. This is
/// essential for S5: a curl stored under the core/grip pain-management pattern
/// must not award blanket core/grip credit, and a lateral raise or triceps
/// extension must not inherit the full vertical-press profile.
class ExerciseMuscleMap {
  const ExerciseMuscleMap();

  static const Map<String, _MuscleProfile> _namedTracks = {
    'sub:hinge:bridge_hamstring_curl': _MuscleProfile(
      primary: {MajorMuscleGroup.hamstrings},
      secondary: {MajorMuscleGroup.glutes},
    ),
    'sub:hinge:light_sl_rdl': _MuscleProfile(
      primary: {MajorMuscleGroup.hamstrings},
      secondary: {MajorMuscleGroup.glutes},
    ),
    'sub:pushHorizontal:floor_press': _MuscleProfile(
      primary: {MajorMuscleGroup.chest},
      secondary: {MajorMuscleGroup.delts, MajorMuscleGroup.triceps},
    ),
    'sub:pullVertical:lower_back_pull_up': _MuscleProfile(
      primary: {MajorMuscleGroup.back},
      secondary: {MajorMuscleGroup.biceps},
    ),
    'sub:pullHorizontal:lower_back_chest_supported_row': _MuscleProfile(
      primary: {MajorMuscleGroup.back},
      secondary: {MajorMuscleGroup.biceps},
    ),
    'sub:pushVertical:lower_back_bodyweight_dip': _MuscleProfile(
      primary: {MajorMuscleGroup.triceps},
      secondary: {MajorMuscleGroup.chest, MajorMuscleGroup.delts},
    ),
    'sub:coreGrip:db_curl': _MuscleProfile(
      primary: {MajorMuscleGroup.biceps},
    ),
    'sub:pushVertical:lateral_raise': _MuscleProfile(
      primary: {MajorMuscleGroup.delts},
    ),
    'sub:pushVertical:overhead_triceps': _MuscleProfile(
      primary: {MajorMuscleGroup.triceps},
    ),
    // Dips occupy the triceps-pump slot in S5; credited as triceps to keep
    // the per-slot stimulus accounting clean (they also hit chest/delts, but
    // those are covered by the horizontal-push and lateral-raise slots).
    'sub:pushVertical:dip': _MuscleProfile(
      primary: {MajorMuscleGroup.triceps},
    ),
  };

  /// Exact-name fallbacks preserve legacy/imported named-exercise history
  /// without applying fuzzy substring rules or an unrelated pattern profile.
  static const Map<String, _MuscleProfile> _legacyNamedExercises = {
    'bridge hamstring curl': _MuscleProfile(
      primary: {MajorMuscleGroup.hamstrings},
      secondary: {MajorMuscleGroup.glutes},
    ),
    'light single-leg rdl (bodyweight/12 lb)': _MuscleProfile(
      primary: {MajorMuscleGroup.hamstrings},
      secondary: {MajorMuscleGroup.glutes},
    ),
    'floor press': _MuscleProfile(
      primary: {MajorMuscleGroup.chest},
      secondary: {MajorMuscleGroup.delts, MajorMuscleGroup.triceps},
    ),
    'wall push-up (pain-free range)': _MuscleProfile(
      primary: {MajorMuscleGroup.chest},
      secondary: {MajorMuscleGroup.delts, MajorMuscleGroup.triceps},
    ),
    'db curl': _MuscleProfile(primary: {MajorMuscleGroup.biceps}),
    'self-resisted curl': _MuscleProfile(
      primary: {MajorMuscleGroup.biceps},
    ),
    'lateral raise': _MuscleProfile(primary: {MajorMuscleGroup.delts}),
    'prone y-raise': _MuscleProfile(primary: {MajorMuscleGroup.delts}),
    'overhead triceps extension': _MuscleProfile(
      primary: {MajorMuscleGroup.triceps},
    ),
    'diamond push-up': _MuscleProfile(
      primary: {MajorMuscleGroup.triceps},
    ),
  };

  static const Map<MovementPattern, _MuscleProfile> _patterns = {
    MovementPattern.squat: _MuscleProfile(
      primary: {MajorMuscleGroup.quads},
      secondary: {MajorMuscleGroup.glutes},
    ),
    MovementPattern.hinge: _MuscleProfile(
      primary: {MajorMuscleGroup.hamstrings},
      secondary: {MajorMuscleGroup.glutes},
    ),
    MovementPattern.pushHorizontal: _MuscleProfile(
      primary: {MajorMuscleGroup.chest},
      secondary: {MajorMuscleGroup.delts, MajorMuscleGroup.triceps},
    ),
    MovementPattern.pushVertical: _MuscleProfile(
      primary: {MajorMuscleGroup.delts},
      secondary: {MajorMuscleGroup.triceps},
    ),
    MovementPattern.pullVertical: _MuscleProfile(
      primary: {MajorMuscleGroup.back},
      secondary: {MajorMuscleGroup.biceps},
    ),
    MovementPattern.pullHorizontal: _MuscleProfile(
      primary: {MajorMuscleGroup.back},
      secondary: {MajorMuscleGroup.biceps},
    ),
    MovementPattern.coreGrip: _MuscleProfile(
      primary: {MajorMuscleGroup.coreGrip},
    ),
    MovementPattern.kneeHealth: _MuscleProfile(),
  };

  Map<MajorMuscleGroup, double> contributionFor(SetLog set) {
    if (set.isWarmup) return const {};
    return contributionForExercise(
      trackKey: set.trackKey,
      pattern: set.pattern,
      exerciseName: set.exerciseName,
    );
  }

  /// Returns the same explicit profile used for completed sets without
  /// requiring recommendation scoring to manufacture a synthetic SetLog.
  Map<MajorMuscleGroup, double> contributionForExercise({
    required String trackKey,
    required MovementPattern pattern,
    String? exerciseName,
  }) {
    if (trackKey.startsWith('warmup:') || trackKey == 'atg_block') {
      return const {};
    }

    final normalizedName = exerciseName?.trim().toLowerCase();
    final named = _namedTracks[trackKey] ??
        (normalizedName == null
            ? null
            : _legacyNamedExercises[normalizedName]);
    if (named != null) return named.effectiveSets;

    // An unknown named/substitute track is safer left uncredited than treated
    // as the broad pain-management pattern it happens to use.
    if (trackKey.startsWith('sub:')) return const {};

    return _patterns[pattern]!.effectiveSets;
  }
}

class _MuscleProfile {
  final Set<MajorMuscleGroup> primary;
  final Set<MajorMuscleGroup> secondary;

  const _MuscleProfile({this.primary = const {}, this.secondary = const {}});

  Map<MajorMuscleGroup, double> get effectiveSets => {
        for (final muscle in primary) muscle: 1.0,
        for (final muscle in secondary)
          if (!primary.contains(muscle)) muscle: 0.5,
      };
}

/// Only completed work at RIR 0 through the inclusive RIR 3+ boundary counts
/// as hypertrophy stimulus. Warm-ups, zero-value entries, and RIR 4+ work do
/// not count.
class TargetEffortPolicy {
  final Set<Rir> qualifyingRir;

  const TargetEffortPolicy({
    this.qualifyingRir = const {
      Rir.rir0,
      Rir.rir1,
      Rir.rir2,
      Rir.rir3plus,
    },
  });

  bool qualifies(SetLog set) =>
      !set.isWarmup && set.value > 0 && qualifyingRir.contains(set.rir);
}

/// Converts persisted session history into normalized stimulus events.
///
/// Structured [CardioCompletion] is authoritative whenever present. Legacy
/// template/duration inference runs only for older logs where it is null.
class SessionLogStimulusAdapter {
  final ExerciseMuscleMap muscleMap;
  final TargetEffortPolicy effortPolicy;

  const SessionLogStimulusAdapter({
    this.muscleMap = const ExerciseMuscleMap(),
    this.effortPolicy = const TargetEffortPolicy(),
  });

  Iterable<MuscleStimulusEvent> strengthEvents(SessionLog log) sync* {
    const strengthTemplates = {
      SessionTypeId.s1,
      SessionTypeId.s2,
      SessionTypeId.s4,
      SessionTypeId.s5,
    };
    if (!strengthTemplates.contains(log.templateId)) return;

    for (var index = 0; index < log.setLogs.length; index++) {
      final set = log.setLogs[index];
      if (!effortPolicy.qualifies(set)) continue;
      final contribution = muscleMap.contributionFor(set);
      if (contribution.isEmpty) continue;
      yield MuscleStimulusEvent(
        sourceId: '${log.id}:set:$index',
        performedAt: log.completedAt,
        effectiveSets: contribution,
      );
    }
  }

  Iterable<AerobicStimulusEvent> aerobicEvents(SessionLog log) sync* {
    final structured = log.cardioCompletion;
    if (structured != null) {
      final expectedProtocol = _expectedStructuredProtocol(log);
      if (structured.protocol.type != expectedProtocol) return;
      final durationMinutes = structured.completedDurationSeconds ~/ 60;
      if (_qualifiesStructuredCardio(structured)) {
        yield AerobicStimulusEvent(
          sourceId: '${log.id}:${structured.protocol.type.name}',
          protocol: structured.protocol.type,
          performedAt: log.completedAt,
          durationMinutes: durationMinutes,
        );
      }
      return;
    }

    yield* _legacyAerobicEvents(log);
  }

  bool _qualifiesStructuredCardio(CardioCompletion completion) =>
      switch (completion.protocol.type) {
        CardioProtocolType.norwegian4x4 =>
          completion.completedWorkIntervals >= 4 &&
              completion.completedWorkSeconds >= 960,
        CardioProtocolType.rehit =>
          completion.completedWorkIntervals >= 2 &&
              completion.completedWorkSeconds >= 40,
        CardioProtocolType.zone2Base =>
          completion.completedDurationSeconds >= 1800,
      };

  CardioProtocolType? _expectedStructuredProtocol(SessionLog log) {
    switch (log.templateId) {
      case SessionTypeId.s3:
        return CardioProtocolType.norwegian4x4;
      case SessionTypeId.s6:
        return CardioProtocolType.zone2Base;
      case SessionTypeId.s7:
        return CardioProtocolType.rehit;
      case SessionTypeId.s2:
        return log.tier == SessionTier.extended
            ? CardioProtocolType.rehit
            : null;
      case SessionTypeId.s1:
      case SessionTypeId.s4:
      case SessionTypeId.s5:
        return null;
    }
  }

  Iterable<AerobicStimulusEvent> _legacyAerobicEvents(
    SessionLog log,
  ) sync* {
    if (log.durationMinutes <= 0) return;

    switch (log.templateId) {
      case SessionTypeId.s3:
        if (log.countsAs.contains(FloorCategory.intensity) &&
            log.durationMinutes >=
                sessionTypes[SessionTypeId.s3]!.fullDurationMin) {
          yield AerobicStimulusEvent(
            sourceId: '${log.id}:norwegian4x4',
            protocol: CardioProtocolType.norwegian4x4,
            performedAt: log.completedAt,
            durationMinutes: log.durationMinutes,
          );
        }
        break;
      case SessionTypeId.s6:
        if (log.countsAs.contains(FloorCategory.aerobic) &&
            log.durationMinutes >=
                sessionTypes[SessionTypeId.s6]!.minDurationMin!) {
          yield AerobicStimulusEvent(
            sourceId: '${log.id}:zone2',
            protocol: CardioProtocolType.zone2Base,
            performedAt: log.completedAt,
            durationMinutes: log.durationMinutes,
          );
        }
        break;
      case SessionTypeId.s7:
        if (log.countsAs.contains(FloorCategory.intensity) &&
            log.durationMinutes >=
                sessionTypes[SessionTypeId.s7]!.minDurationMin!) {
          yield AerobicStimulusEvent(
            sourceId: '${log.id}:rehit',
            protocol: CardioProtocolType.rehit,
            performedAt: log.completedAt,
            durationMinutes: log.durationMinutes,
          );
        }
        break;
      case SessionTypeId.s2:
        if (log.rehitFinisherCompleted &&
            log.countsAs.contains(FloorCategory.intensity)) {
          yield AerobicStimulusEvent(
            sourceId: '${log.id}:rehit-finisher',
            protocol: CardioProtocolType.rehit,
            performedAt: log.completedAt,
            // Legacy SessionLog stores only total strength-session duration.
            // Retain finisher credit without claiming all of it was REHIT.
            durationMinutes:
                sessionTypes[SessionTypeId.s7]!.fullDurationMin,
          );
        }
        break;
      case SessionTypeId.s1:
      case SessionTypeId.s4:
      case SessionTypeId.s5:
        break;
    }
  }
}

class StimulusLedgerEngine {
  const StimulusLedgerEngine();

  StimulusLedgerSnapshot buildFromSessionLogs({
    required Iterable<SessionLog> logs,
    required DateTime asOf,
    SessionLogStimulusAdapter adapter = const SessionLogStimulusAdapter(),
  }) {
    final muscleEvents = <MuscleStimulusEvent>[];
    final aerobicEvents = <AerobicStimulusEvent>[];
    for (final log in logs) {
      muscleEvents.addAll(adapter.strengthEvents(log));
      aerobicEvents.addAll(adapter.aerobicEvents(log));
    }
    return build(
      muscleEvents: muscleEvents,
      aerobicEvents: aerobicEvents,
      asOf: asOf,
    );
  }

  /// Pure aggregation over exact trailing 7-day and 28-day intervals.
  StimulusLedgerSnapshot build({
    required Iterable<MuscleStimulusEvent> muscleEvents,
    required Iterable<AerobicStimulusEvent> aerobicEvents,
    required DateTime asOf,
  }) {
    final eligibleMuscleEvents = muscleEvents
        .where((event) => !event.performedAt.isAfter(asOf))
        .toList();
    final eligibleAerobicEvents = aerobicEvents
        .where(
          (event) =>
              event.durationMinutes > 0 && !event.performedAt.isAfter(asOf),
        )
        .toList()
      ..sort((a, b) => a.performedAt.compareTo(b.performedAt));

    final muscles = <MajorMuscleGroup, MuscleStimulusStatus>{};
    for (final muscle in MajorMuscleGroup.values) {
      final events = eligibleMuscleEvents
          .where((event) => (event.effectiveSets[muscle] ?? 0) > 0)
          .toList();
      muscles[muscle] = MuscleStimulusStatus(
        muscle: muscle,
        effectiveSets7d: _muscleTotal(events, muscle, asOf, 7),
        effectiveSets28d: _muscleTotal(events, muscle, asOf, 28),
        daysSinceLastStimulus: _daysSinceLast(
          events.map((event) => event.performedAt),
          asOf,
        ),
      );
    }

    final aerobic = <CardioProtocolType, AerobicProtocolStatus>{};
    for (final protocol in CardioProtocolType.values) {
      final events = eligibleAerobicEvents
          .where((event) => event.protocol == protocol)
          .toList();
      final last7 = events
          .where((event) => _inRollingWindow(event.performedAt, asOf, 7))
          .toList();
      final last28 = events
          .where((event) => _inRollingWindow(event.performedAt, asOf, 28))
          .toList();
      aerobic[protocol] = AerobicProtocolStatus(
        protocol: protocol,
        sessions7d: last7.length,
        sessions28d: last28.length,
        separateDays7d: _distinctDays(
          last7.map((event) => event.performedAt),
        ),
        separateDays28d: _distinctDays(
          last28.map((event) => event.performedAt),
        ),
        durationMinutes7d:
            last7.fold(0, (sum, event) => sum + event.durationMinutes),
        durationMinutes28d:
            last28.fold(0, (sum, event) => sum + event.durationMinutes),
        daysSinceLastStimulus: _daysSinceLast(
          events.map((event) => event.performedAt),
          asOf,
        ),
        sessionDurations7d:
            last7.map((event) => event.durationMinutes).toList(),
        sessionDurations28d:
            last28.map((event) => event.durationMinutes).toList(),
      );
    }

    int highIntensityDistinctDays(int days) => _distinctDays(
          eligibleAerobicEvents
              .where(
                (event) =>
                    (event.protocol == CardioProtocolType.norwegian4x4 ||
                        event.protocol == CardioProtocolType.rehit) &&
                    _inRollingWindow(event.performedAt, asOf, days),
              )
              .map((event) => event.performedAt),
        );

    return StimulusLedgerSnapshot(
      asOf: asOf,
      muscles: muscles,
      aerobic: aerobic,
      highIntensityDistinctDays7d: highIntensityDistinctDays(7),
      highIntensityDistinctDays28d: highIntensityDistinctDays(28),
    );
  }

  double _muscleTotal(
    Iterable<MuscleStimulusEvent> events,
    MajorMuscleGroup muscle,
    DateTime asOf,
    int days,
  ) =>
      events
          .where((event) => _inRollingWindow(event.performedAt, asOf, days))
          .fold(
            0.0,
            (sum, event) => sum + (event.effectiveSets[muscle] ?? 0),
          );

  int? _daysSinceLast(Iterable<DateTime> dates, DateTime asOf) {
    DateTime? latest;
    for (final value in dates) {
      if (value.isAfter(asOf)) continue;
      if (latest == null || value.isAfter(latest)) latest = value;
    }
    return latest == null ? null : asOf.difference(latest).inDays;
  }

  int _distinctDays(Iterable<DateTime> dates) =>
      dates.map(_calendarDateKey).toSet().length;

  String _calendarDateKey(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';

  bool _inRollingWindow(DateTime value, DateTime asOf, int days) {
    final start = asOf.subtract(Duration(days: days));
    return !value.isBefore(start) && !value.isAfter(asOf);
  }
}
