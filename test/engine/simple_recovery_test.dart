import 'package:flutter_test/flutter_test.dart';
import 'package:morningcoach/engine/cycling_access.dart';
import 'package:morningcoach/engine/decision_engine.dart';
import 'package:morningcoach/engine/progression_engine.dart';
import 'package:morningcoach/engine/queue_engine.dart';
import 'package:morningcoach/models/cardio_protocol.dart';
import 'package:morningcoach/models/check_in.dart';
import 'package:morningcoach/models/equipment.dart';
import 'package:morningcoach/models/exercise_state.dart';
import 'package:morningcoach/models/ladders.dart';
import 'package:morningcoach/models/lower_back_recovery.dart';
import 'package:morningcoach/models/movement_pattern.dart';
import 'package:morningcoach/models/pain.dart';
import 'package:morningcoach/models/recovery_snapshot.dart';
import 'package:morningcoach/models/session_type.dart';
import 'package:morningcoach/models/set_log.dart';
import 'package:morningcoach/models/user_settings.dart';

void main() {
  final day = DateTime(2026, 9, 10);
  UserSettings rebuild({
    BackRebuildStage stage = BackRebuildStage.bridges,
    LowerBackRecoveryStage extensionStage =
        LowerBackRecoveryStage.isometricHold,
    BikeReturnStep bike = BikeReturnStep.walkOnly,
    bool extensions = false,
    bool bikePaused = false,
  }) => UserSettings(
    stationaryBikePaused: bikePaused,
    recoveryBackExtensionsEnabled: extensions,
    lowerBackRecovery: LowerBackRecoveryState(
      active: true,
      stage: extensionStage,
      rebuildStage: stage,
      bikeReturnStep: bike,
      preRecoveryHingeLoad: 90,
    ),
  );

  DecisionEngineOutput plan({
    UserSettings? settings,
    int minutes = 35,
    int subjective = 4,
    SessionTypeId id = SessionTypeId.s1,
    List<PainFlag> pain = const [],
  }) => const DecisionEngine().decide(
    DecisionEngineInput(
      checkinHistory: const [],
      checkin: CheckIn(
        date: day,
        timeMinutes: minutes,
        subjective: subjective,
        pain: pain,
        timestamp: day,
      ),
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
      settings: settings ?? rebuild(),
      today: day,
      forcedSessionId: id,
    ),
  );

  test('Back rebuild plans every strength family inside every hard window', () {
    for (final id in [
      SessionTypeId.s1,
      SessionTypeId.s2,
      SessionTypeId.s4,
      SessionTypeId.s5,
    ]) {
      for (final minutes in [20, 35, 60]) {
        for (final stage in BackRebuildStage.values) {
          final result = plan(
            id: id,
            minutes: minutes,
            settings: rebuild(stage: stage),
          ).trace.plan!;
          expect(result.sessionId, id);
          expect(result.lowerBackRecoveryMode, isTrue);
          expect(result.estimatedDurationMin, lessThanOrEqualTo(minutes));
          expect(
            result.exercises.any((e) => e.trackKey == 'hinge'),
            isFalse,
            reason: '${id.name} $minutes ${stage.name}',
          );
          // A loaded rebuild deadlift is always the final work exercise.
          final work = result.exercises.where((e) => !e.isWarmup).toList();
          final loadedIndex = work.indexWhere(
            (e) =>
                e.trackKey == backRebuildBlockDeadlift.trackKey ||
                e.trackKey == backRebuildRomanianDeadlift.trackKey,
          );
          if (loadedIndex >= 0) {
            expect(loadedIndex, work.length - 1);
          }
        }
      }
    }
  });

  test('leg symptoms still block Back rebuild even on green days', () {
    for (final tag in PainTag.values) {
      final output = plan(
        pain: [
          PainFlag(
            region: BodyRegion.lowerBack,
            severity: PainSeverity.mild,
            flaggedDate: day,
            tags: {tag},
          ),
        ],
      );
      expect(output.trace.plan, isNull, reason: tag.name);
    }
  });

  test('readiness restrictions still stop strength progression', () {
    final result = plan(id: SessionTypeId.s2, subjective: 1).trace.plan!;
    expect(
      result.exercises
          .where((e) => !e.isWarmup)
          .every((e) => !e.progressionEligible),
      isTrue,
    );
  });

  test('the bike return walks Zone 2 and keeps intervals closed', () {
    final walk = plan(id: SessionTypeId.s6, minutes: 60).trace.plan!;
    expect(walk.sessionId, SessionTypeId.s6);
    expect(walk.cardioPrescription!.protocol.isWalk, isTrue);
    expect(
      walk.cardioPrescription!.protocol.type,
      CardioProtocolType.zone2Base,
    );
    expect(walk.sessionName, contains('uphill walk'));

    for (final id in [SessionTypeId.s3, SessionTypeId.s7]) {
      final result = plan(id: id, minutes: 60).trace.plan!;
      expect([
        SessionTypeId.s3,
        SessionTypeId.s7,
      ], isNot(contains(result.sessionId)));
    }
    final s2 = plan(id: SessionTypeId.s2, minutes: 60).trace.plan!;
    expect(s2.optionalRehitFinisherReserved, isFalse);

    final ride = plan(
      id: SessionTypeId.s6,
      minutes: 60,
      settings: rebuild(bike: BikeReturnStep.zone2Ride),
    ).trace.plan!;
    expect(ride.cardioPrescription!.protocol.isWalk, isFalse);

    final paused = plan(
      id: SessionTypeId.s6,
      minutes: 60,
      settings: const UserSettings(stationaryBikePaused: true),
    ).trace.plan!;
    expect(paused.cardioPrescription!.protocol.isWalk, isTrue);
  });

  test('cycling access follows the manual pause and each bike step', () {
    expect(CyclingAccess.fromSettings(const UserSettings()).rehit, isTrue);
    final paused = CyclingAccess.fromSettings(
      const UserSettings(stationaryBikePaused: true),
    );
    expect(paused.any, isFalse);
    expect(paused.allowsSession(SessionTypeId.s6, slotMinutes: 60), isTrue);

    final expectations = {
      BikeReturnStep.walkOnly: (false, false, false),
      BikeReturnStep.zone2Ride: (true, false, false),
      BikeReturnStep.fourByFour: (true, true, false),
      BikeReturnStep.complete: (true, true, true),
    };
    for (final entry in expectations.entries) {
      final access = CyclingAccess.fromSettings(rebuild(bike: entry.key));
      expect(
        (access.zone2Ride, access.fourByFour, access.rehit),
        entry.value,
        reason: entry.key.name,
      );
      expect(
        access.allowsSession(SessionTypeId.s3, slotMinutes: 35),
        entry.value.$2,
      );
      // Below 35 minutes the 4×4 slot can only become REHIT.
      expect(
        access.allowsSession(SessionTypeId.s3, slotMinutes: 20),
        entry.value.$3,
      );
      expect(
        access.allowsSession(SessionTypeId.s7, slotMinutes: 20),
        entry.value.$3,
      );
    }
    // The manual pause outranks a completed bike return.
    expect(
      CyclingAccess.fromSettings(
        rebuild(bike: BikeReturnStep.complete, bikePaused: true),
      ).any,
      isFalse,
    );
  });

  test('a legacy deadlift re-entry extension stage never loads a hinge', () {
    final result = plan(
      settings: rebuild(
        extensions: true,
        extensionStage: LowerBackRecoveryStage.deadliftReentry,
      ),
    ).trace.plan!;
    final extension = result.exercises.singleWhere(
      (e) => e.trackKey == lowerBackRecoveryTrackKey,
    );
    expect(extension.loadTotal, isNull);
    expect(
      result.exercises.where(
        (e) =>
            e.trackKey == 'hinge' ||
            e.trackKey == backRebuildBlockDeadlift.trackKey ||
            e.trackKey == backRebuildRomanianDeadlift.trackKey,
      ),
      isEmpty,
    );
  });

  test('normal alternative starts independently and respects sharp pain', () {
    final result = plan(
      settings: const UserSettings(deadliftAlternative: true),
      minutes: 60,
    ).trace.plan!;
    expect(
      result.exercises.map((e) => e.trackKey),
      containsAll([
        alternativeGluteBridge.trackKey,
        alternativeHamstringCurl.trackKey,
      ]),
    );
    expect(result.exercises.any((e) => e.trackKey == 'hinge'), isFalse);
    expect(
      result.exercises
          .firstWhere((e) => e.trackKey == alternativeGluteBridge.trackKey)
          .loadTotal!,
      lessThan(90),
    );
    final painful = plan(
      settings: const UserSettings(deadliftAlternative: true),
      minutes: 60,
      pain: [
        PainFlag(
          region: BodyRegion.lowerBack,
          severity: PainSeverity.sharp,
          flaggedDate: day,
        ),
      ],
    ).trace.plan!;
    expect(
      painful.exercises.where(
        (e) => !e.isWarmup && e.trackKey == bridgeHamstringCurl.trackKey,
      ),
      hasLength(1),
    );
    expect(
      painful.exercises.any(
        (e) => e.trackKey == alternativeGluteBridge.trackKey,
      ),
      isFalse,
    );
  });

  test(
    'legacy recovery pull-up and dip tracks keep tempo/pause-only progression',
    () {
      for (final e in [lowerBackRecoveryPullUp, lowerBackRecoveryDip]) {
        var state = ExerciseState(trackKey: e.trackKey, pattern: e.pattern);
        for (var i = 0; i < 5; i++) {
          state = const ProgressionEngine().evaluateSession(
            state,
            [
              SetLog(
                trackKey: e.trackKey,
                pattern: e.pattern,
                exerciseName: e.name,
                weight: 0,
                value: 15,
                rir: Rir.rir3plus,
                timestamp: day,
              ),
            ],
            equipmentConfig: const EquipmentConfig(),
            sessionDate: day,
          );
        }
        expect(state.microStepStage, 2);
        expect(state.ladderStepIndex, 0);
        expect(state.currentLoad, 0);
        expect(
          const ProgressionEngine()
              .progressionPresentationFor(state, const EquipmentConfig())
              .nextLabel,
          contains('no added load'),
        );
      }
    },
  );
}
