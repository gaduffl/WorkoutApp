import 'package:flutter_test/flutter_test.dart';
import 'package:morningcoach/engine/recovery_program_engine.dart';
import 'package:morningcoach/models/recovery_program.dart';
import 'package:morningcoach/models/pain.dart';

void main() {
  const engine = RecoveryProgramEngine();
  final day = DateTime(2026, 9, 7);
  RecoveryObservation observation({
    Set<PainTag> symptoms = const {},
    bool improved = true,
    bool worse = false,
  }) => RecoveryObservation(
    date: day,
    pain: 1,
    sittingMinutes: 30,
    function: improved ? RecoveryFunction.better : RecoveryFunction.unchanged,
    symptoms: symptoms,
    delayedWorse: worse,
  );

  test('resolved neurological symptoms still require explicit review', () {
    var state = engine.observe(
      const RecoveryProgram(),
      observation(symptoms: {PainTag.tingling}),
    );
    expect(state.reviewRequired, isTrue);
    state = engine.observe(state, observation());
    expect(state.reviewRequired, isTrue);
    expect(engine.canAdvance(state, day), isFalse);
  });

  test('unchanged and incomplete work cannot earn an increase', () {
    var state = engine.observe(
      const RecoveryProgram(),
      observation(improved: false),
    );
    state = engine.complete(
      state,
      date: day,
      completeDose: false,
      worse: false,
    );
    state = engine.observe(
      state,
      RecoveryObservation(
        date: day.add(const Duration(days: 1)),
        pain: 1,
        sittingMinutes: 30,
        function: RecoveryFunction.unchanged,
      ),
    );
    expect(state.toleratedExposures, 0);
    expect(engine.canAdvance(state, day.add(const Duration(days: 1))), isFalse);
  });

  test('worsening pauses the offending exercise even at minimum dose', () {
    final state = engine.flare(
      const RecoveryProgram(),
      day,
      provoking: {RecoveryExercise.abdominalActivation},
    );
    expect(state.phase, RecoveryPhase.flareUp);
    expect(
      state.pausedExercises,
      contains(RecoveryExercise.abdominalActivation),
    );
    expect(state.toleratedExposures, 0);
  });

  test('old backups migrate to flare-up and do not inherit progression', () {
    final state = RecoveryProgram.fromJson(const {});
    expect(state.phase, RecoveryPhase.flareUp);
    expect(state.toleratedExposures, 0);
    expect(state.bikePaused, isTrue);
  });

  test('symptoms, choices and independent doses survive persistence', () {
    final state = engine.observe(
      const RecoveryProgram(
        selected: {
          RecoveryExercise.abdominalActivation,
          RecoveryExercise.floorPress,
        },
        doses: {RecoveryExercise.floorPress: RecoveryDose(reps: 7, load: 10)},
      ),
      observation(symptoms: {PainTag.tingling}),
    );
    final restored = RecoveryProgram.fromJson(state.toJson());
    expect(restored.toJson(), state.toJson());
  });

  test(
    'full exposures require next-day feedback and phases only move explicitly',
    () {
      var state = engine.observe(const RecoveryProgram(), observation());
      for (var n = 0; n < 2; n++) {
        final session = day.add(Duration(days: n));
        state = engine.complete(
          state,
          date: session,
          completeDose: true,
          worse: false,
          exercises: {RecoveryExercise.abdominalActivation},
        );
        expect(engine.canAdvance(state, session), isFalse);
        state = engine.observe(
          state,
          RecoveryObservation(
            date: session.add(const Duration(days: 1)),
            pain: 1,
            sittingMinutes: 30,
            function: RecoveryFunction.better,
          ),
        );
      }
      final reviewDay = day.add(const Duration(days: 2));
      expect(state.phase, RecoveryPhase.flareUp);
      expect(engine.canAdvance(state, reviewDay), isTrue);
      state = engine.advance(state, reviewDay);
      expect(state.phase, RecoveryPhase.rebuild);
      expect(state.toleratedExposures, 0);
      state = state.copyWith(toleratedExposures: 2);
      expect(() => engine.advance(state, reviewDay), throwsStateError);
      state = engine.recordAssessment(state, reviewDay);
      expect(engine.advance(state, reviewDay).phase, RecoveryPhase.hingeReturn);
    },
  );

  test(
    'dose changes use equipment steps and never increase a paused movement',
    () {
      var state = engine.observe(
        const RecoveryProgram(
          phase: RecoveryPhase.hingeReturn,
          toleratedExposures: 2,
          selected: {RecoveryExercise.gluteBridge},
        ),
        observation(),
      );
      expect(
        () => engine.adjustDose(
          state,
          RecoveryExercise.gluteBridge,
          const RecoveryDose(load: 6),
          day,
        ),
        throwsStateError,
      );
      state = engine.recordAssessment(state, day);
      expect(
        () => engine.adjustDose(
          state,
          RecoveryExercise.gluteBridge,
          const RecoveryDose(load: 5),
          day,
        ),
        throwsArgumentError,
      );
      expect(
        () => engine.adjustDose(
          state,
          RecoveryExercise.gluteBridge,
          const RecoveryDose(load: 10),
          day,
        ),
        throwsArgumentError,
      );
      final changed = engine.adjustDose(
        state,
        RecoveryExercise.gluteBridge,
        const RecoveryDose(load: 6),
        day,
      );
      expect(changed.dose(RecoveryExercise.gluteBridge).load, 6);
      expect(changed.toleratedExposures, 0);
      state = state.copyWith(pausedExercises: {RecoveryExercise.gluteBridge});
      expect(
        () => engine.adjustDose(
          state,
          RecoveryExercise.gluteBridge,
          const RecoveryDose(reps: 6),
          day,
        ),
        throwsStateError,
      );
    },
  );

  test(
    'minimum-dose worsening stays paused until an explicit settled re-trial',
    () {
      var state = engine.complete(
        engine.observe(const RecoveryProgram(), observation()),
        date: day,
        completeDose: true,
        worse: true,
        exercises: {RecoveryExercise.abdominalActivation},
      );
      expect(state.sessions, hasLength(1));
      expect(engine.due(state, day), isFalse);
      expect(
        engine.allowed(
          state,
          RecoveryExercise.abdominalActivation,
          alternative: false,
        ),
        isFalse,
      );
      state = engine.observe(
        state,
        RecoveryObservation(
          date: day.add(const Duration(days: 1)),
          pain: 1,
          sittingMinutes: 30,
          function: RecoveryFunction.unchanged,
        ),
      );
      state = engine.retrial(
        state,
        RecoveryExercise.abdominalActivation,
        day.add(const Duration(days: 1)),
      );
      expect(state.pausedExercises, isEmpty);
      expect(state.toleratedExposures, 0);
    },
  );

  test('exit cannot restore a deadlift before full-range tolerance', () {
    var state = engine.observe(
      const RecoveryProgram(
        phase: RecoveryPhase.returnToTraining,
        toleratedExposures: 2,
        selected: {RecoveryExercise.deadlift},
        doses: {RecoveryExercise.deadlift: RecoveryDose(load: 12)},
      ),
      observation(),
    );
    state = engine.recordAssessment(state, day);
    expect(
      () => engine.validateExit(state, day, alternative: false),
      throwsStateError,
    );
    state = state.copyWith(
      doses: {
        RecoveryExercise.deadlift: const RecoveryDose(
          load: 12,
          rangePercent: 100,
        ),
      },
    );
    expect(
      () => engine.validateExit(state, day, alternative: false),
      returnsNormally,
    );
    expect(
      () => engine.validateExit(state, day, alternative: true),
      throwsStateError,
    );
    state = state.copyWith(
      selected: {RecoveryExercise.gluteBridge, RecoveryExercise.hamstringCurl},
    );
    expect(
      () => engine.validateExit(state, day, alternative: true),
      returnsNormally,
    );
  });

  test(
    'selection changes retain pending feedback and its provoking movements',
    () {
      var state = engine.complete(
        engine.observe(const RecoveryProgram(), observation()),
        date: day,
        completeDose: true,
        worse: false,
        exercises: {RecoveryExercise.abdominalActivation},
      );
      state = engine.select(state, RecoveryExercise.floorPress, true);
      expect(state.pendingSession, day);
      expect(state.pendingCompleteDose, isFalse);
      state = engine.observe(
        state,
        RecoveryObservation(
          date: day.add(const Duration(days: 1)),
          pain: 1,
          sittingMinutes: 10,
          function: RecoveryFunction.unchanged,
        ),
      );
      expect(state.phase, RecoveryPhase.flareUp);
      expect(
        state.pausedExercises,
        contains(RecoveryExercise.abdominalActivation),
      );
    },
  );

  test(
    'supported DB work starts only with an explicitly chosen achievable small load',
    () {
      final state = engine.observe(
        const RecoveryProgram(
          phase: RecoveryPhase.rebuild,
          selected: {RecoveryExercise.floorPress},
        ),
        observation(),
      );
      expect(
        engine.allowed(state, RecoveryExercise.floorPress, alternative: false),
        isFalse,
      );
      expect(
        () => engine.adjustDose(
          state,
          RecoveryExercise.floorPress,
          const RecoveryDose(load: 24),
          day,
        ),
        throwsArgumentError,
      );
      final chosen = engine.adjustDose(
        state,
        RecoveryExercise.floorPress,
        const RecoveryDose(load: 12),
        day,
      );
      final retried = engine.retrial(
        chosen.copyWith(pausedExercises: {RecoveryExercise.floorPress}),
        RecoveryExercise.floorPress,
        day,
      );
      expect(
        () => engine.adjustDose(
          retried,
          RecoveryExercise.floorPress,
          const RecoveryDose(load: 12),
          day,
        ),
        returnsNormally,
      );
      expect(
        engine.allowed(chosen, RecoveryExercise.floorPress, alternative: false),
        isTrue,
      );
      expect(
        () => engine.adjustDose(
          chosen,
          RecoveryExercise.floorPress,
          const RecoveryDose(load: 18),
          day,
        ),
        throwsStateError,
      );
    },
  );
}
