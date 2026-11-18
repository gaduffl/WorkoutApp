import 'package:flutter_test/flutter_test.dart';
import 'package:morningcoach/engine/decision_engine.dart';
import 'package:morningcoach/engine/queue_engine.dart';
import 'package:morningcoach/engine/stimulus_ledger_engine.dart';
import 'package:morningcoach/engine/strength_duration_engine.dart';
import 'package:morningcoach/models/check_in.dart';
import 'package:morningcoach/models/couch_stretch.dart';
import 'package:morningcoach/models/exercise_metric.dart';
import 'package:morningcoach/models/exercise_state.dart';
import 'package:morningcoach/models/floor_category.dart';
import 'package:morningcoach/models/hov_foot_warmup.dart';
import 'package:morningcoach/models/kickstand_rdl.dart';
import 'package:morningcoach/models/lower_back_recovery.dart';
import 'package:morningcoach/models/movement_pattern.dart';
import 'package:morningcoach/models/pain.dart';
import 'package:morningcoach/models/plan.dart';
import 'package:morningcoach/models/recovery_snapshot.dart';
import 'package:morningcoach/models/session_log.dart';
import 'package:morningcoach/models/session_type.dart';
import 'package:morningcoach/models/user_settings.dart';

void main() {
  final today = DateTime(2026, 1, 20);

  SessionLog log(SessionTypeId id, int daysAgo, Set<FloorCategory> counts) =>
      SessionLog(
        id: '${id.name}-$daysAgo',
        templateId: id,
        tier: SessionTier.full,
        date: today.subtract(Duration(days: daysAgo)),
        setLogs: const [],
        plannedWorkSets: 6,
        completedWorkSets: 6,
        durationMinutes: 30,
        countsAs: counts,
      );

  LowerBackRecoveryState rebuild(
    BackRebuildStage? stage, {
    bool deadliftDue = true,
  }) => stage == null
      ? const LowerBackRecoveryState()
      : LowerBackRecoveryState(
          active: true,
          rebuildStage: stage,
          preRecoveryHingeLoad: 90,
          bikeReturnStep: BikeReturnStep.walkOnly,
          recoverySessionDates: deadliftDue
              ? const []
              : [today.subtract(const Duration(days: 1))],
        );

  SessionPlan plan(
    SessionTypeId id, {
    int minutes = 35,
    UserSettings settings = const UserSettings(),
    List<PainFlag> pain = const [],
    Map<String, ExerciseState> extraStates = const {},
  }) {
    final output = const DecisionEngine().decide(
      DecisionEngineInput(
        checkin: CheckIn(
          date: today,
          timeMinutes: minutes,
          subjective: 4,
          pain: pain,
          timestamp: today,
        ),
        todaySnapshot: RecoverySnapshot(
          date: today,
          hrvRmssd: 50,
          restingHr: 60,
          sleepScore: 90,
        ),
        recoveryHistory: List.generate(
          20,
          (i) => RecoverySnapshot(
            date: today.subtract(Duration(days: i + 1)),
            hrvRmssd: 50,
            restingHr: 60,
            sleepScore: 90,
          ),
        ),
        checkinHistory: const [],
        sessionLogs: [
          log(SessionTypeId.s1, 2, {FloorCategory.strength}),
          log(SessionTypeId.s4, 4, {FloorCategory.strength}),
          log(SessionTypeId.s3, 3, {FloorCategory.intensity}),
          log(SessionTypeId.s6, 2, {FloorCategory.aerobic}),
          log(SessionTypeId.s7, 5, {FloorCategory.intensity}),
        ],
        exerciseStates: {
          'squat': ExerciseState(
            trackKey: 'squat',
            pattern: MovementPattern.squat,
            currentLoad: 24,
            lastTrainedDate: today.subtract(const Duration(days: 2)),
          ),
          'hinge': ExerciseState(
            trackKey: 'hinge',
            pattern: MovementPattern.hinge,
            currentLoad: 90,
            lastTrainedDate: today.subtract(const Duration(days: 2)),
          ),
          ...extraStates,
        },
        queueState: const QueueState(),
        settings: settings,
        today: today,
        forcedSessionId: id,
      ),
    );
    final result = output.trace.plan;
    expect(result, isNotNull, reason: output.trace.restReason);
    return result!;
  }

  PlannedExercise? kickstand(SessionPlan plan) => plan.exercises
      .where((exercise) => KickstandRdl.isTrack(exercise.trackKey))
      .singleOrNull;

  List<(String, int)> work(SessionPlan plan) => [
    for (final exercise in plan.exercises)
      if (!exercise.isWarmup) (exercise.trackKey, exercise.sets),
  ];

  bool isPrepDrill(PlannedExercise exercise) =>
      exercise.trackKey == 'atg_block' ||
      exercise.trackKey == 'warmup:big3' ||
      exercise.trackKey.startsWith('warmup:s') ||
      CouchStretch.isTrack(exercise.trackKey);

  test(
    'ends the warm-up on lower-body days only, in every window and stage',
    () {
      for (final stage in [null, ...BackRebuildStage.values]) {
        for (final deadliftDue in [true, false]) {
          for (final id in const [
            SessionTypeId.s1,
            SessionTypeId.s2,
            SessionTypeId.s4,
            SessionTypeId.s5,
          ]) {
            for (final minutes in [20, 35, 60]) {
              final reason = '$stage due:$deadliftDue ${id.name} $minutes';
              final p = plan(
                id,
                minutes: minutes,
                settings: UserSettings(
                  lowerBackRecovery: rebuild(stage, deadliftDue: deadliftDue),
                ),
              );
              expect(
                p.estimatedDurationMin,
                lessThanOrEqualTo(minutes),
                reason: reason,
              );
              expect(
                const StrengthDurationEstimator().estimateMinutes(p.exercises),
                p.estimatedDurationMin,
                reason: reason,
              );
              final entry = kickstand(p);
              if (id != SessionTypeId.s1 && id != SessionTypeId.s4) {
                expect(entry, isNull, reason: reason);
                continue;
              }
              if (entry == null) {
                // Only a full 20-minute window may squeeze it out, and then it
                // gives way before the couch stretches.
                expect(minutes, 20, reason: reason);
                expect(
                  p.exercises.where((e) => CouchStretch.isTrack(e.trackKey)),
                  hasLength(2),
                  reason: reason,
                );
                continue;
              }
              final index = p.exercises.indexOf(entry);
              // Right after the prep, Big 3 and couch stretches, before any
              // load ramp or work.
              expect(
                p.exercises.take(index).every(isPrepDrill),
                isTrue,
                reason: reason,
              );
              expect(
                isPrepDrill(p.exercises[index + 1]),
                isFalse,
                reason: reason,
              );
              expect(entry.isWarmup, isTrue, reason: reason);
              expect(entry.progressionEligible, isFalse, reason: reason);
              expect(entry.countsTowardStrengthCompletion, isFalse);
              expect(entry.metric, ExerciseMetric.minutes, reason: reason);
              final planned = minutes == 20 ? 2 : 3;
              expect(entry.targetRange, (planned, planned), reason: reason);
              expect(entry.sets, 1, reason: reason);
            }
          }
        }
      }
    },
  );

  test('spells out the rounds and drops the band in travel mode', () {
    final full = kickstand(plan(SessionTypeId.s1))!;
    expect(full.name, 'Mini-band kickstand RDL');
    expect(full.isTravel, isFalse);
    expect(full.instruction, contains('Round 1: 8 slow reps on the left leg'));
    expect(full.instruction, contains('Round 2: the same'));
    expect(full.instruction, contains('Mini-band just above the knees'));
    expect(full.instruction, contains('back toe stays planted'));
    expect(full.instruction, contains('Ease off or skip a side'));

    final short = kickstand(plan(SessionTypeId.s1, minutes: 20))!;
    expect(short.instruction, contains('8 slow reps on the left leg'));
    expect(short.instruction, isNot(contains('Round 2')));

    final travel = kickstand(
      plan(SessionTypeId.s4, settings: const UserSettings(travelMode: true)),
    )!;
    expect(travel.name, 'Kickstand RDL (no band)');
    expect(travel.isTravel, isTrue);
    expect(travel.instruction, contains('No band while travelling'));
    expect(travel.instruction, isNot(contains('Mini-band')));
  });

  test('the switch, back and hip flags and a sharp knee leave it out', () {
    final off = plan(
      SessionTypeId.s1,
      settings: const UserSettings(kickstandRdlEnabled: false),
    );
    expect(kickstand(off), isNull);

    PainFlag flag(BodyRegion region, PainSeverity severity) =>
        PainFlag(region: region, severity: severity, flaggedDate: today);
    for (final (pain, kept) in [
      (flag(BodyRegion.lowerBack, PainSeverity.mild), false),
      (flag(BodyRegion.lowerBack, PainSeverity.sharp), false),
      (flag(BodyRegion.hip, PainSeverity.mild), false),
      (flag(BodyRegion.kneeRight, PainSeverity.sharp), false),
      (flag(BodyRegion.kneeLeft, PainSeverity.mild), true),
      (flag(BodyRegion.shoulderLeft, PainSeverity.sharp), true),
    ]) {
      final p = plan(SessionTypeId.s4, minutes: 60, pain: [pain]);
      expect(
        kickstand(p) != null,
        kept,
        reason: '${pain.region.name} ${pain.severity.name}',
      );
    }

    // A persisted back freeze keeps it out on later days too.
    final frozen = plan(
      SessionTypeId.s1,
      extraStates: {
        'hinge': ExerciseState(
          trackKey: 'hinge',
          pattern: MovementPattern.hinge,
          currentLoad: 90,
          lastTrainedDate: today.subtract(const Duration(days: 2)),
          painFrozen: true,
          painRegion: BodyRegion.lowerBack,
          painSeverity: PainSeverity.mild,
          painFlaggedDate: today.subtract(const Duration(days: 2)),
        ),
      },
    );
    expect(kickstand(frozen), isNull);
  });

  test('may trim work but never costs the session or the couch stretches', () {
    // A full 20-minute deadlift day: the couch stretches stay, the primer
    // gives way, and the work is exactly as with the switch off.
    final deadliftDay = UserSettings(
      lowerBackRecovery: rebuild(BackRebuildStage.blockDeadlift),
    );
    final short = plan(SessionTypeId.s1, minutes: 20, settings: deadliftDay);
    final shortOff = plan(
      SessionTypeId.s1,
      minutes: 20,
      settings: deadliftDay.copyWith(kickstandRdlEnabled: false),
    );
    expect(kickstand(short), isNull);
    expect(
      short.exercises.where((e) => CouchStretch.isTrack(e.trackKey)),
      hasLength(2),
    );
    expect(work(short), work(shortOff));
    expect(short.estimatedDurationMin, shortOff.estimatedDurationMin);

    // With room to spare it stays and the budgeter trims work around it.
    final noDeadlift = UserSettings(
      lowerBackRecovery: rebuild(
        BackRebuildStage.blockDeadlift,
        deadliftDue: false,
      ),
    );
    final trimmed = plan(SessionTypeId.s1, settings: noDeadlift);
    final untrimmed = plan(
      SessionTypeId.s1,
      settings: noDeadlift.copyWith(kickstandRdlEnabled: false),
    );
    expect(kickstand(trimmed), isNotNull);
    expect(trimmed.estimatedDurationMin, lessThanOrEqualTo(35));
    expect(
      trimmed.plannedWorkSets,
      lessThanOrEqualTo(untrimmed.plannedWorkSets),
    );

    // Five-minute couch holds leave no room for both drills: only the
    // stretches drop out, so the plan is exactly the one without them.
    final longHolds = plan(
      SessionTypeId.s1,
      minutes: 20,
      settings: const UserSettings(
        couchStretchSeconds: CouchStretch.maxHoldSeconds,
      ),
    );
    final noCouch = plan(
      SessionTypeId.s1,
      minutes: 20,
      settings: const UserSettings(couchStretchEnabled: false),
    );
    expect(kickstand(longHolds), isNotNull);
    expect(
      longHolds.exercises.where((e) => CouchStretch.isTrack(e.trackKey)),
      isEmpty,
    );
    expect(work(longHolds), work(noCouch));
    expect(longHolds.estimatedDurationMin, noCouch.estimatedDurationMin);
  });

  test('with HOV it follows the Big 3 only when no lift is cut', () {
    var seen = false;
    for (final stage in [null, ...BackRebuildStage.values]) {
      for (final id in [SessionTypeId.s1, SessionTypeId.s4]) {
        for (final minutes in [20, 35, 60]) {
          final reason = '$stage ${id.name} $minutes';
          final settings = UserSettings(
            hovFootWarmupEnabled: true,
            lowerBackRecovery: rebuild(stage),
          );
          final on = plan(id, minutes: minutes, settings: settings);
          final off = plan(
            id,
            minutes: minutes,
            settings: settings.copyWith(kickstandRdlEnabled: false),
          );
          expect(work(on), work(off), reason: reason);
          expect(
            on.estimatedDurationMin,
            lessThanOrEqualTo(minutes),
            reason: reason,
          );
          expect(
            const StrengthDurationEstimator().estimateMinutes(on.exercises),
            on.estimatedDurationMin,
            reason: reason,
          );
          expect(
            on.exercises
                .where((e) => HovFootWarmup.isTrack(e.trackKey))
                .fold<int>(0, (n, e) => n + e.sets),
            16,
            reason: reason,
          );
          final entry = kickstand(on);
          if (entry == null) continue;
          seen = true;
          final index = on.exercises.indexOf(entry);
          expect(
            on.exercises[index - 1].trackKey,
            'warmup:big3',
            reason: reason,
          );
          expect(
            on.exercises
                .take(index)
                .every(
                  (e) =>
                      HovFootWarmup.isTrack(e.trackKey) ||
                      e.trackKey == 'warmup:big3',
                ),
            isTrue,
            reason: reason,
          );
          final firstStretch = on.exercises.indexWhere(
            (e) => CouchStretch.isTrack(e.trackKey),
          );
          if (firstStretch >= 0) {
            expect(firstStretch, greaterThan(index), reason: reason);
          }
        }
      }
    }
    expect(seen, isTrue, reason: 'a 60-minute HOV day has room for it');
  });

  test('earns no stimulus credit', () {
    expect(
      const ExerciseMuscleMap().contributionForExercise(
        trackKey: KickstandRdl.trackKey,
        pattern: MovementPattern.kneeHealth,
        exerciseName: 'Mini-band kickstand RDL',
      ),
      isEmpty,
    );
  });
}
