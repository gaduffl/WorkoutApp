import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:morningcoach/data/app_database.dart';
import 'package:morningcoach/data/repository.dart';
import 'package:morningcoach/engine/rehit_eligibility_engine.dart';
import 'package:morningcoach/engine/rest_day_rehit_engine.dart';
import 'package:morningcoach/engine/schedule_fit_engine.dart';
import 'package:morningcoach/models/check_in.dart';
import 'package:morningcoach/models/decision_trace.dart';
import 'package:morningcoach/models/exercise_state.dart';
import 'package:morningcoach/models/exercise_metric.dart';
import 'package:morningcoach/models/movement_pattern.dart';
import 'package:morningcoach/models/pain.dart';
import 'package:morningcoach/models/plan.dart';
import 'package:morningcoach/models/session_type.dart';
import 'package:morningcoach/models/set_log.dart';
import 'package:morningcoach/models/user_settings.dart';
import 'package:morningcoach/notifications/notification_service.dart';
import 'package:morningcoach/state/app_controller.dart';
import 'package:morningcoach/ui/screens/today_screen.dart';

void main() {
  SessionPlan plan(
    SessionTypeId id,
    SessionTier tier, {
    bool travelMode = false,
    bool? reserveRehitFinisher,
  }) =>
      SessionPlan(
        sessionId: id,
        sessionName: 'Test',
        tier: tier,
        exercises: const [],
        estimatedDurationMin: 60,
        travelMode: travelMode,
        optionalRehitFinisherReserved: reserveRehitFinisher ??
            (id == SessionTypeId.s2 && tier == SessionTier.extended),
      );

  test('optional REHIT hint matches the logger eligibility and copy', () {
    expect(
      optionalRehitFinisherHint(
        plan(SessionTypeId.s2, SessionTier.extended),
        safetyEligible: true,
      ),
      optionalRehitFinisherMessage,
    );
    expect(
      optionalRehitFinisherHint(
        plan(
          SessionTypeId.s2,
          SessionTier.extended,
          reserveRehitFinisher: false,
        ),
        safetyEligible: true,
      ),
      isNull,
    );
    expect(
      optionalRehitFinisherMessage,
      'Optional finisher: CAROL REHIT Intense after the strength work. Complete the bike-guided preset; both sprints earn intensity credit.',
    );
    expect(
      optionalRehitFinisherHint(
        plan(SessionTypeId.s2, SessionTier.full),
        safetyEligible: true,
      ),
      isNull,
    );
    expect(
      optionalRehitFinisherHint(
        plan(SessionTypeId.s1, SessionTier.extended),
        safetyEligible: true,
      ),
      isNull,
    );
    expect(
      optionalRehitFinisherHint(
        plan(SessionTypeId.s2, SessionTier.extended),
        safetyEligible: false,
      ),
      isNull,
    );
  });

  test('pain-blocked alternatives are hidden while partial work stays offered',
      () {
    const unavailable = ScoredCandidate(
      sessionId: SessionTypeId.s1,
      tier: SessionTier.full,
      score: 15,
      scoreTerms: {
        'base': 10,
        painNoSafeWorkScoreTerm: 0,
      },
    );
    const partiallyAvailable = ScoredCandidate(
      sessionId: SessionTypeId.s2,
      tier: SessionTier.full,
      score: 100,
      scoreTerms: {'muscleWeeklyDeficit': 100},
    );

    expect(isPainSafeAlternative(unavailable), isFalse);
    expect(candidateReason(unavailable), contains('no pain-safe work'));
    expect(isPainSafeAlternative(partiallyAvailable), isTrue);
  });

  DecisionTrace trace(
    DateTime now, {
    SessionPlan? sessionPlan,
    List<ScoredCandidate> candidates = const [],
  }) =>
      DecisionTrace(
        date: DateTime(now.year, now.month, now.day),
        checkin: CheckIn(
          date: DateTime(now.year, now.month, now.day),
          timeMinutes: 35,
          subjective: 4,
          timestamp: now,
        ),
        recovery: const RecoveryTrace(
          hrvZToday: 0,
          hrvTrend3: 0,
          sleepScore: 90,
          rhrDev: 0,
          bucket: ReadinessBucket.green,
          compositeScore: 80,
        ),
        candidates: candidates,
        firedRules: const [],
        plan: sessionPlan ?? plan(SessionTypeId.s1, SessionTier.full),
        queue: const QueueTraceInfo(
          pointerBefore: SessionTypeId.s1,
          servedBefore: {},
        ),
      );

  group('rest-day REHIT offer', () {
    final now = DateTime(2026, 7, 15, 13);

    RestDayRehitResult restDay({
      bool eligible = true,
      bool checkInMissing = false,
      ScheduleSlotSource source = ScheduleSlotSource.weekdayHabit,
    }) =>
        RestDayRehitResult(
          closedReasons: eligible
              ? const []
              : const [RestDayRehitClosedReason.trainingLoggedToday],
          observedAt: now,
          suggestedNudgeTime:
              eligible ? DateTime(2026, 7, 15, 17, 30) : null,
          slotSource: eligible ? source : null,
          checkInMissing: checkInMissing,
        );

    Widget todayWith(RestDayRehitResult result) =>
        ChangeNotifierProvider<AppController>.value(
          value: _RestDayController(result),
          child: MaterialApp(home: TodayScreen(trace: trace(now))),
        );

    testWidgets('an untrained GREEN day offers the short bike session',
        (tester) async {
      await tester.pumpWidget(todayWith(restDay()));
      await tester.pump();

      expect(find.byKey(const Key('today-rest-day-rehit')), findsOneWidget);
      expect(find.text('Nothing logged today'), findsOneWidget);
      expect(
        find.text('Around 17:30 fits the time you usually train.'),
        findsOneWidget,
      );
    });

    testWidgets('a closed rest-day decision shows nothing', (tester) async {
      await tester.pumpWidget(todayWith(restDay(eligible: false)));
      await tester.pump();
      expect(find.byKey(const Key('today-rest-day-rehit')), findsNothing);
    });

    testWidgets('without a check-in the in-app offer stays hidden',
        (tester) async {
      // The push reminder may still go out; logging high-intensity work
      // without a readiness decision must not be one tap away.
      await tester.pumpWidget(todayWith(restDay(checkInMissing: true)));
      await tester.pump();
      expect(find.byKey(const Key('today-rest-day-rehit')), findsNothing);
    });

    test('the slot line claims a habit only when one was learned', () {
      expect(
        restDayRehitSlotLine(restDay()),
        'Around 17:30 fits the time you usually train.',
      );
      expect(
        restDayRehitSlotLine(
          restDay(source: ScheduleSlotSource.overallHabit),
        ),
        contains('usually train'),
      );
      expect(
        restDayRehitSlotLine(restDay(source: ScheduleSlotSource.fallback)),
        'There is still room for it around 17:30.',
      );
    });
  });

  testWidgets('finisher hint appears only from the shared safe preview',
      (tester) async {
    final now = DateTime(2026, 7, 15, 10);
    final safe = RehitEligibilityResult(
      closedReasons: const [],
      observedAt: now,
      suggestedNudgeTime: DateTime(2026, 7, 15, 15),
    );
    final s2 = plan(SessionTypeId.s2, SessionTier.extended);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: _EligibilityController(safe, loggedToday: false),
        child: MaterialApp(
          home: TodayScreen(trace: trace(now, sessionPlan: s2)),
        ),
      ),
    );
    await tester.pump();
    expect(find.text(optionalRehitFinisherMessage), findsOneWidget);

    final unsafe = RehitEligibilityResult(
      closedReasons: const [RehitClosedReason.readinessNotGreen],
      observedAt: now,
      suggestedNudgeTime: null,
    );
    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: _EligibilityController(unsafe, loggedToday: false),
        child: MaterialApp(
          home: TodayScreen(trace: trace(now, sessionPlan: s2)),
        ),
      ),
    );
    await tester.pump();
    expect(find.text(optionalRehitFinisherMessage), findsNothing);
  });

  testWidgets('Today displays a planned micro-progression instruction',
      (tester) async {
    const cue =
        'Micro-progression - tempo: use a slow 3-second eccentric on every rep';
    const cuePlan = SessionPlan(
      sessionId: SessionTypeId.s1,
      sessionName: 'Strength',
      tier: SessionTier.full,
      estimatedDurationMin: 35,
      exercises: [
        PlannedExercise(
          trackKey: 'squat',
          pattern: MovementPattern.squat,
          name: 'Goblet squat',
          sets: 3,
          targetRange: (6, 10),
          rirTarget: Rir.rir2,
          instruction: cue,
        ),
      ],
    );
    final now = DateTime(2026, 7, 15, 10);
    final unsafe = RehitEligibilityResult(
      closedReasons: const [RehitClosedReason.readinessNotGreen],
      observedAt: now,
      suggestedNudgeTime: null,
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: _EligibilityController(unsafe, loggedToday: false),
        child: MaterialApp(
          home: TodayScreen(trace: trace(now, sessionPlan: cuePlan)),
        ),
      ),
    );
    await tester.pump();

    expect(find.text(cue), findsOneWidget);
  });

  testWidgets('Today makes Plank progress and changed prescription explicit',
      (tester) async {
    const progressedPlan = SessionPlan(
      sessionId: SessionTypeId.s5,
      sessionName: 'Core progression',
      tier: SessionTier.full,
      estimatedDurationMin: 20,
      exercises: [
        PlannedExercise(
          trackKey: 'coreGrip',
          pattern: MovementPattern.coreGrip,
          name: 'Plank',
          sets: 2,
          metric: ExerciseMetric.seconds,
          targetRange: (20, 60),
          suggestedValue: 60,
          progressionFraction: 0.75,
          progressionLabel: '60-second Plank · Difficulty 1 of 5',
          nextProgressionLabel: 'Next: controlled transition',
          prescriptionChange: 'Target increased: 55 → 60 seconds',
          rirTarget: Rir.rir2,
        ),
      ],
    );
    final now = DateTime(2026, 7, 15, 10);
    final unsafe = RehitEligibilityResult(
      closedReasons: const [RehitClosedReason.readinessNotGreen],
      observedAt: now,
      suggestedNudgeTime: null,
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: _EligibilityController(unsafe, loggedToday: false),
        child: MaterialApp(
          home: TodayScreen(trace: trace(now, sessionPlan: progressedPlan)),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Progressed since last time'), findsOneWidget);
    expect(find.text('Target increased: 55 → 60 seconds'), findsOneWidget);
    expect(find.text('60-second Plank · Difficulty 1 of 5'), findsOneWidget);
    expect(find.text('Next: controlled transition'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });

  testWidgets('Today and notification gate consume the same eligible result',
      (tester) async {
    final now = DateTime(2026, 7, 15, 10);
    final eligibility = RehitEligibilityResult(
      closedReasons: const [],
      observedAt: now,
      suggestedNudgeTime: DateTime(2026, 7, 15, 15),
    );
    final controller = _EligibilityController(eligibility);

    expect(
      secondRehitNudgeSyncDecision(
        enabled: true,
        eligibility: controller.secondRehitEligibility,
        scheduledDay: null,
      ),
      SecondRehitNudgeSyncDecision.schedule,
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: MaterialApp(home: TodayScreen(trace: trace(now))),
      ),
    );
    await tester.pump();

    expect(find.text('Optional CAROL REHIT Intense'), findsOneWidget);
    expect(find.text('Log CAROL preset'), findsOneWidget);
  });

  testWidgets('unsafe shared result produces neither UI offer nor nudge',
      (tester) async {
    final now = DateTime(2026, 7, 15, 10);
    final eligibility = RehitEligibilityResult(
      closedReasons: const [RehitClosedReason.contraindicatingPainActive],
      observedAt: now,
      suggestedNudgeTime: null,
    );
    final controller = _EligibilityController(eligibility);

    expect(
      secondRehitNudgeSyncDecision(
        enabled: true,
        eligibility: controller.secondRehitEligibility,
        scheduledDay: null,
      ),
      SecondRehitNudgeSyncDecision.cancel,
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: MaterialApp(home: TodayScreen(trace: trace(now))),
      ),
    );
    await tester.pump();

    expect(find.text('Optional CAROL REHIT Intense'), findsNothing);
    expect(find.text('Log CAROL preset'), findsNothing);
  });

  testWidgets('travel alternatives hide restored CAROL-only candidates',
      (tester) async {
    final now = DateTime(2026, 7, 15, 10);
    final unsafe = RehitEligibilityResult(
      closedReasons: const [RehitClosedReason.rehitUnavailableDueToTravel],
      observedAt: now,
      suggestedNudgeTime: null,
    );
    final travelTrace = trace(
      now,
      sessionPlan: plan(
        SessionTypeId.s1,
        SessionTier.compressed,
        travelMode: true,
      ),
      candidates: const [
        ScoredCandidate(
          sessionId: SessionTypeId.s3,
          tier: SessionTier.full,
          score: 300,
          scoreTerms: {'norwegian4x4Due': 300},
        ),
        ScoredCandidate(
          sessionId: SessionTypeId.s7,
          tier: SessionTier.compressed,
          score: 200,
          scoreTerms: {'rehitFallbackDue': 200},
        ),
        ScoredCandidate(
          sessionId: SessionTypeId.s2,
          tier: SessionTier.compressed,
          score: 100,
          scoreTerms: {'muscleWeeklyDeficit': 100},
        ),
      ],
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: _EligibilityController(unsafe, loggedToday: false),
        child: MaterialApp(home: TodayScreen(trace: travelTrace)),
      ),
    );
    await tester.pump();

    expect(find.text('Norwegian 4x4 (CAROL)'), findsNothing);
    expect(find.text('REHIT'), findsNothing);
    expect(find.text('Upper Strength'), findsOneWidget);
  });

  testWidgets('current travel settings hide and disable a restored S3 primary',
      (tester) async {
    final now = DateTime.now();
    final unsafe = RehitEligibilityResult(
      closedReasons: const [RehitClosedReason.rehitUnavailableDueToTravel],
      observedAt: now,
      suggestedNudgeTime: null,
    );
    final controller = _EligibilityController(
      unsafe,
      loggedToday: false,
      planUsable: false,
      highIntensityUsable: false,
    )..settings = const UserSettings(travelMode: true);
    final stale = SessionPlan(
      sessionId: SessionTypeId.s3,
      sessionName: 'Norwegian 4x4 (CAROL)',
      tier: SessionTier.full,
      exercises: const [],
      estimatedDurationMin: 35,
      travelMode: false,
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: MaterialApp(
          home: TodayScreen(trace: trace(now, sessionPlan: stale)),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Plan unavailable in current safety mode'), findsOneWidget);
    expect(find.textContaining('Regenerate it or redo today\'s check-in'), findsOneWidget);
    expect(find.text('Norwegian 4x4 (CAROL)'), findsNothing);
    expect(find.text('Log cardio attempt'), findsNothing);
    expect(find.text('Start session'), findsNothing);
  });

  testWidgets(
      'a completed prescribed recovery session is done and cannot be logged again',
      (tester) async {
    final now = DateTime.now();
    final unsafe = RehitEligibilityResult(
      closedReasons: const [RehitClosedReason.readinessNotGreen],
      observedAt: now,
      suggestedNudgeTime: null,
    );
    const recoveryPlan = SessionPlan(
      sessionId: SessionTypeId.s6,
      sessionName: '20-minute recovery',
      tier: SessionTier.compressed,
      exercises: [],
      estimatedDurationMin: 20,
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: _EligibilityController(unsafe, loggedToday: true),
        child: MaterialApp(
          home: TodayScreen(
            trace: trace(now, sessionPlan: recoveryPlan),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Session complete'), findsOneWidget);
    expect(find.text('Log cardio attempt'), findsNothing);
  });

  testWidgets('a partial logged attempt hides primary-plan alternatives',
      (tester) async {
    final now = DateTime.now();
    final unavailableRehit = RehitEligibilityResult(
      closedReasons: const [RehitClosedReason.firstSessionBelowMinimumCompletion],
      observedAt: now,
      suggestedNudgeTime: null,
    );
    final partialTrace = trace(
      now,
      candidates: const [
        ScoredCandidate(
          sessionId: SessionTypeId.s2,
          tier: SessionTier.full,
          score: 100,
          scoreTerms: {'muscleWeeklyDeficit': 100},
        ),
      ],
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: _EligibilityController(
          unavailableRehit,
          loggedToday: true,
          doneToday: false,
        ),
        child: MaterialApp(home: TodayScreen(trace: partialTrace)),
      ),
    );
    await tester.pump();

    expect(find.text('Session complete'), findsNothing);
    expect(find.text('Other options today'), findsNothing);
    expect(find.text('Upper Strength'), findsNothing);
    expect(find.text('Optional CAROL REHIT Intense'), findsNothing);
  });

  testWidgets('a partial strength attempt hides Start and disables re-check-in',
      (tester) async {
    final now = DateTime.now();
    final unavailableRehit = RehitEligibilityResult(
      closedReasons: const [RehitClosedReason.firstSessionBelowMinimumCompletion],
      observedAt: now,
      suggestedNudgeTime: null,
    );
    const strengthPlan = SessionPlan(
      sessionId: SessionTypeId.s1,
      sessionName: 'Partial strength',
      tier: SessionTier.full,
      estimatedDurationMin: 35,
      exercises: [
        PlannedExercise(
          trackKey: 'squat',
          pattern: MovementPattern.squat,
          name: 'Squat',
          sets: 3,
          targetRange: (6, 10),
          rirTarget: Rir.rir2,
        ),
      ],
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: _EligibilityController(
          unavailableRehit,
          loggedToday: true,
          doneToday: false,
        ),
        child: MaterialApp(
          home: TodayScreen(
            trace: trace(now, sessionPlan: strengthPlan),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Workout attempt saved'), findsOneWidget);
    expect(find.text('Start session'), findsNothing);
    final redo = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.restart_alt),
    );
    expect(redo.onPressed, isNull);
  });

  testWidgets('a partial cardio attempt hides its primary logging action',
      (tester) async {
    final now = DateTime.now();
    final unavailableRehit = RehitEligibilityResult(
      closedReasons: const [RehitClosedReason.firstSessionBelowMinimumCompletion],
      observedAt: now,
      suggestedNudgeTime: null,
    );
    const cardioPlan = SessionPlan(
      sessionId: SessionTypeId.s6,
      sessionName: 'Partial Zone 2',
      tier: SessionTier.full,
      exercises: [],
      estimatedDurationMin: 35,
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: _EligibilityController(
          unavailableRehit,
          loggedToday: true,
          doneToday: false,
        ),
        child: MaterialApp(
          home: TodayScreen(
            trace: trace(now, sessionPlan: cardioPlan),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Workout attempt saved'), findsOneWidget);
    expect(find.text('Log cardio attempt'), findsNothing);
  });

  testWidgets('persisted frozen sharp hip pain filters leg-heavy alternatives',
      (tester) async {
    final now = DateTime.now();
    final unavailableRehit = RehitEligibilityResult(
      closedReasons: const [RehitClosedReason.contraindicatingPainActive],
      observedAt: now,
      suggestedNudgeTime: null,
    );
    final controller = _EligibilityController(
      unavailableRehit,
      loggedToday: false,
    )..exerciseStates['squat'] = ExerciseState(
        trackKey: 'squat',
        pattern: MovementPattern.squat,
        painFrozen: true,
        painSeverity: PainSeverity.sharp,
        painRegion: BodyRegion.hip,
        painFlaggedDate: now.subtract(const Duration(days: 2)),
      );
    final persistedPainTrace = trace(
      now,
      sessionPlan: plan(SessionTypeId.s5, SessionTier.full),
      candidates: const [
        ScoredCandidate(
          sessionId: SessionTypeId.s1,
          tier: SessionTier.full,
          score: 200,
          scoreTerms: {'muscleWeeklyDeficit': 200},
        ),
        ScoredCandidate(
          sessionId: SessionTypeId.s2,
          tier: SessionTier.full,
          score: 100,
          scoreTerms: {'muscleWeeklyDeficit': 100},
        ),
      ],
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: MaterialApp(home: TodayScreen(trace: persistedPainTrace)),
      ),
    );
    await tester.pump();

    expect(find.text('Lower Strength'), findsNothing);
    expect(find.text('Upper Strength'), findsOneWidget);
  });

  testWidgets('mounted Today adopts a recomputed controller trace',
      (tester) async {
    final now = DateTime.now();
    final unsafe = RehitEligibilityResult(
      closedReasons: const [RehitClosedReason.rehitUnavailableDueToTravel],
      observedAt: now,
      suggestedNudgeTime: null,
    );
    final stalePlan = SessionPlan(
      sessionId: SessionTypeId.s3,
      sessionName: 'Norwegian 4x4 (CAROL)',
      tier: SessionTier.full,
      exercises: const [],
      estimatedDurationMin: 35,
    );
    final refreshedPlan = SessionPlan(
      sessionId: SessionTypeId.s6,
      sessionName: 'Travel-safe Zone 2',
      tier: SessionTier.full,
      exercises: const [],
      estimatedDurationMin: 35,
    );
    final staleTrace = trace(now, sessionPlan: stalePlan);
    final refreshedTrace = trace(now, sessionPlan: refreshedPlan);
    final controller = _EligibilityController(
      unsafe,
      loggedToday: false,
      planUsable: false,
      highIntensityUsable: false,
    )
      ..settings = const UserSettings(travelMode: true)
      ..todayTrace = staleTrace;

    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: MaterialApp(home: TodayScreen(trace: staleTrace)),
      ),
    );
    await tester.pump();
    expect(find.text('Plan unavailable in current safety mode'), findsOneWidget);

    controller.publishTrace(refreshedTrace);
    await tester.pump();

    expect(find.text('Plan unavailable in current safety mode'), findsNothing);
    expect(find.text('Travel-safe Zone 2'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Log cardio attempt'), 200);
    expect(find.text('Log cardio attempt'), findsOneWidget);
  });

  testWidgets(
      'header plan card is hidden after session is logged so the stale '
      'REHIT/4x4 safety warning cannot shadow the completion state',
      (tester) async {
    final now = DateTime(2026, 7, 15, 10);
    final s7Plan = SessionPlan(
      sessionId: SessionTypeId.s7,
      sessionName: 'REHIT',
      tier: SessionTier.full,
      exercises: const [],
      estimatedDurationMin: 16,
    );
    final unsafe = RehitEligibilityResult(
      closedReasons: const [RehitClosedReason.intensityWithinTrailing48Hours],
      observedAt: now,
      suggestedNudgeTime: null,
    );
    // simulates a logged REHIT session whose 48h recovery gate now blocks the
    // original S7 plan -> staleHighIntensityPlan would otherwise be true.
    final controller = _EligibilityController(
      unsafe,
      loggedToday: true,
      doneToday: true,
      planUsable: false,
      highIntensityUsable: false,
    );
    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: MaterialApp(
          home: TodayScreen(trace: trace(now, sessionPlan: s7Plan)),
        ),
      ),
    );
    await tester.pump();
    // The "stale plan" copy must NOT appear once the session is done.
    expect(find.text('Plan unavailable in current safety mode'), findsNothing);
    expect(
      find.textContaining(
        'This recommendation cannot be started under the current',
      ),
      findsNothing,
    );
    // The completion card must still be on screen.
    expect(find.text('Session complete'), findsOneWidget);
  });

  testWidgets(
      'header plan card stays visible while in-progress so the safety '
      'warning still explains why the plan cannot be started',
      (tester) async {
    final now = DateTime(2026, 7, 15, 10);
    final s7Plan = SessionPlan(
      sessionId: SessionTypeId.s7,
      sessionName: 'REHIT',
      tier: SessionTier.full,
      exercises: const [],
      estimatedDurationMin: 16,
    );
    final unsafe = RehitEligibilityResult(
      closedReasons: const [RehitClosedReason.intensityWithinTrailing48Hours],
      observedAt: now,
      suggestedNudgeTime: null,
    );
    // The session is NOT done -> the stale plan warning must still surface
    // so the user knows the recommendation cannot be started right now.
    final controller = _EligibilityController(
      unsafe,
      loggedToday: false,
      doneToday: false,
      planUsable: false,
      highIntensityUsable: false,
    );
    await tester.pumpWidget(
      ChangeNotifierProvider<AppController>.value(
        value: controller,
        child: MaterialApp(
          home: TodayScreen(trace: trace(now, sessionPlan: s7Plan)),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Plan unavailable in current safety mode'), findsOneWidget);
    expect(
      find.textContaining(
        'This recommendation cannot be started under the current',
      ),
      findsOneWidget,
    );
  });
}

/// Drives only the rest-day offer; every other Today decision is left at the
/// fixture defaults so the card cannot be shown by an unrelated stub.
class _RestDayController extends _EligibilityController {
  final RestDayRehitResult restDay;

  _RestDayController(this.restDay)
      : super(
          RehitEligibilityResult(
            closedReasons: const [RehitClosedReason.noFirstSession],
            observedAt: restDay.observedAt,
            suggestedNudgeTime: null,
          ),
          loggedToday: false,
        );

  @override
  RestDayRehitResult restDayRehitEligibilityAt(DateTime nowLocal) => restDay;
}

class _EligibilityController extends AppController {
  final RehitEligibilityResult eligibility;
  final bool loggedToday;
  final bool doneToday;
  final bool planUsable;
  final bool highIntensityUsable;

  _EligibilityController(
    this.eligibility, {
    this.loggedToday = true,
    bool? doneToday,
    this.planUsable = true,
    this.highIntensityUsable = true,
  })  : doneToday = doneToday ?? loggedToday,
        super(Repository(AppDatabase()));

  @override
  RehitEligibilityResult get secondRehitEligibility => eligibility;

  @override
  RehitEligibilityResult rehitFinisherPreviewEligibility(
    SessionPlan? plan, {
    DateTime? nowLocal,
  }) =>
      eligibility;

  @override
  bool get sessionDoneToday => doneToday;

  @override
  bool get sessionLoggedToday => loggedToday;

  @override
  bool isPlanUsableNow(SessionPlan? plan, {DateTime? nowLocal}) {
    // Mirror the real short-circuit: non-S3/S7 plans are always usable in the
    // fixture regardless of the high-intensity gate, so tests that publish a
    // refreshed non-high-intensity trace (e.g. Travel-safe Zone 2 / S6) can
    // watch the safety warning disappear without re-stubbing the controller.
    if (plan == null ||
        (plan.sessionId != SessionTypeId.s3 &&
            plan.sessionId != SessionTypeId.s7)) {
      return true;
    }
    return planUsable;
  }

  @override
  bool isHighIntensityUsableNow({DateTime? nowLocal}) =>
      highIntensityUsable;

  void publishTrace(DecisionTrace trace) {
    todayTrace = trace;
    notifyListeners();
  }
}
