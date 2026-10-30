import 'package:flutter_test/flutter_test.dart';
import 'package:morningcoach/data/serializers.dart';
import 'package:morningcoach/engine/decision_engine.dart';
import 'package:morningcoach/engine/queue_engine.dart';
import 'package:morningcoach/engine/strength_duration_engine.dart';
import 'package:morningcoach/models/check_in.dart';
import 'package:morningcoach/models/couch_stretch.dart';
import 'package:morningcoach/models/exercise_state.dart';
import 'package:morningcoach/models/hov_foot_warmup.dart';
import 'package:morningcoach/models/lower_back_recovery.dart';
import 'package:morningcoach/models/movement_pattern.dart';
import 'package:morningcoach/models/pain.dart';
import 'package:morningcoach/models/recovery_snapshot.dart';
import 'package:morningcoach/models/session_type.dart';
import 'package:morningcoach/models/user_settings.dart';

void main() {
  final day = DateTime(2026, 10, 28);
  DecisionEngineOutput plan({
    int minutes = 35,
    SessionTypeId id = SessionTypeId.s1,
    BackRebuildStage? stage,
    bool travel = false,
    bool enabled = true,
    List<PainFlag> pain = const [],
  }) => const DecisionEngine().decide(
    DecisionEngineInput(
      checkin: CheckIn(
        date: day,
        timestamp: day,
        timeMinutes: minutes,
        subjective: 4,
        pain: pain,
      ),
      checkinHistory: const [],
      todaySnapshot: RecoverySnapshot(
        date: day,
        hrvRmssd: 50,
        restingHr: 60,
        sleepScore: 90,
      ),
      recoveryHistory: List.generate(
        20,
        (i) => RecoverySnapshot(
          date: day.subtract(Duration(days: i + 1)),
          hrvRmssd: 50,
          restingHr: 60,
          sleepScore: 90,
        ),
      ),
      sessionLogs: const [],
      exerciseStates: {
        'hinge': ExerciseState(
          trackKey: 'hinge',
          pattern: MovementPattern.hinge,
          currentLoad: 90,
          ladderStepIndex: 3,
        ),
      },
      queueState: const QueueState(),
      settings: UserSettings(
        hovFootWarmupEnabled: enabled,
        travelMode: travel,
        lowerBackRecovery: LowerBackRecoveryState(
          active: stage != null,
          rebuildStage: stage ?? BackRebuildStage.bridges,
          preRecoveryHingeLoad: 90,
        ),
      ),
      today: day,
      forcedSessionId: id,
    ),
  );

  test(
    'all strength families fit all windows in normal and Back rebuild modes',
    () {
      for (final stage in [null, ...BackRebuildStage.values]) {
        for (final minutes in [20, 35, 60]) {
          for (final id in [
            SessionTypeId.s1,
            SessionTypeId.s2,
            SessionTypeId.s4,
            SessionTypeId.s5,
          ]) {
            final output = plan(minutes: minutes, id: id, stage: stage);
            final p = output.trace.plan;
            final reason =
                '$stage / $minutes / $id: ${output.trace.restReason}';
            expect(p, isNotNull, reason: reason);
            expect(p!.hovFootWarmupEnabled, isTrue);
            expect(
              p.estimatedDurationMin,
              lessThanOrEqualTo(minutes),
              reason: reason,
            );
            expect(
              const StrengthDurationEstimator().estimateMinutes(p.exercises),
              p.estimatedDurationMin,
            );
            expect(
              p.exercises
                  .where((e) => HovFootWarmup.isTrack(e.trackKey))
                  .fold<int>(0, (n, e) => n + e.sets),
              16,
              reason: reason,
            );
            expect(
              p.exercises.any(
                (e) =>
                    e.trackKey == 'atg_block' ||
                    e.trackKey == 'warmup:${id.name}',
              ),
              isFalse,
            );
            expect(p.exercises.any((e) => e.name.contains('McGill')), isTrue);
            expect(
              p.exercises.any((e) => e.countsTowardStrengthCompletion),
              isTrue,
            );
            if (minutes == 20) {
              expect(
                p.exercises
                    .where((e) => e.isCompoundWork && e.sets == 1)
                    .every((e) => !e.progressionEligible),
                isTrue,
                reason: 'A condensed single set must not advance the load.',
              );
            }
            final firstStretch = p.exercises.indexWhere(
              (e) => CouchStretch.isTrack(e.trackKey),
            );
            if (firstStretch >= 0) {
              expect(
                p.exercises
                    .skip(firstStretch)
                    .every((e) => CouchStretch.isTrack(e.trackKey)),
                isTrue,
              );
            }
            expect(
              sessionPlanFromJson(sessionPlanToJson(p)).hovFootWarmupEnabled,
              isTrue,
            );
          }
        }
      }
    },
  );

  test(
    'disabled preserves old prep, cardio stays protocol-owned, travel has no wedge',
    () {
      final original = plan(enabled: false).trace.plan!;
      expect(
        original.exercises.any((e) => HovFootWarmup.isTrack(e.trackKey)),
        isFalse,
      );
      final cardio = plan(id: SessionTypeId.s6, minutes: 60).trace.plan!;
      expect(cardio.hovFootWarmupEnabled, isFalse);
      expect(
        cardio.exercises.any((e) => HovFootWarmup.isTrack(e.trackKey)),
        isFalse,
      );
      final travel = plan(travel: true).trace.plan!;
      expect(
        travel.exercises.where((e) => !e.isWarmup).every((e) => e.isTravel),
        isTrue,
      );
      expect(
        travel.exercises.any(
          (e) =>
              e.trackKey == HovFootWarmup.holdLeft ||
              e.trackKey == HovFootWarmup.holdRight,
        ),
        isFalse,
      );
    },
  );

  test('sharp back and knee flags cannot be bypassed through HOV', () {
    for (final region in [
      BodyRegion.lowerBack,
      BodyRegion.hip,
      BodyRegion.kneeLeft,
    ]) {
      final p = plan(
        id: SessionTypeId.s2,
        pain: [
          PainFlag(
            region: region,
            severity: PainSeverity.sharp,
            flaggedDate: day,
          ),
        ],
      ).trace.plan;
      expect(p, isNotNull);
      expect(
        p!.exercises.any(
          (e) => [
            HovFootWarmup.bridge,
            HovFootWarmup.hinge,
            HovFootWarmup.steps,
          ].contains(e.trackKey),
        ),
        isFalse,
      );
      if (region == BodyRegion.kneeLeft) {
        expect(
          p.exercises.any((e) => HovFootWarmup.isTrack(e.trackKey)),
          isFalse,
        );
      }
    }
  });
}
