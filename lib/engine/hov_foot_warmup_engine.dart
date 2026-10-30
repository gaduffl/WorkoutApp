import '../models/exercise_metric.dart';
import '../models/hov_foot_warmup.dart';
import '../models/movement_pattern.dart';
import '../models/plan.dart';
import '../models/set_log.dart';

/// The supplied sheet contains only Phase 1's exercise rows. Preserve its
/// minimum two C1–C4 rounds and 2×30 s bridge / 3×30 s calf hold per foot.
/// Explicit round entries keep the circuit order even with supersets off.
class HovFootWarmupEngine {
  const HovFootWarmupEngine();

  List<PlannedExercise> build({
    bool travelMode = false,
    bool painAware = false,
    Set<String> excludedTracks = const {},
  }) {
    PlannedExercise exercise(
      String key,
      String name,
      int value,
      String cue, {
      int sets = 1,
      bool timed = false,
    }) => PlannedExercise(
      trackKey: key,
      pattern: MovementPattern.kneeHealth,
      name: name,
      sets: sets,
      metric: timed ? ExerciseMetric.seconds : ExerciseMetric.reps,
      targetRange: (value, value),
      rirTarget: Rir.rir4plus,
      progressionEligible: false,
      isTravel: travelMode,
      instruction:
          '$cue\nZiel: Schmerz unter 3/10; bei 3–5/10 Rücksprache, über 5/10 abbrechen. '
          '${painAware ? '\nNur im schmerzfreien Bereich; bei Knie-, Hüft- oder Rückenbeschwerden die betroffene Bewegung auslassen.' : ''}',
    );
    return [
      exercise(
        HovFootWarmup.bridge,
        'HOV A · Wadenbrücke beidbeinig',
        30,
        'Rückenlage, Knie gebeugt. Über beide Vorfüße die Fersen anheben '
            'und die Wadenbrücke wie gezeigt halten; Rücken nicht überstrecken. '
            '2 × 30 s, etwa 30 s Pause. Beidbeinige Ausgangsvariante.',
        sets: 2,
        timed: true,
      ),
      for (var round = 1; round <= 2; round++) ...[
        exercise(
          HovFootWarmup.roll,
          'HOV C1 · Ganze Abrollbewegung · Runde $round/2',
          10,
          'Gewicht kontrolliert von der Ferse über den ganzen Fuß bis zum '
              'Vorfuß verlagern. Pronation und Supination bewusst wahrnehmen. '
              'C1 → C2 → C3 → C4, danach die nächste Runde.',
        ),
        exercise(
          HovFootWarmup.hinge,
          'HOV C2 · Vorbeuge auf dem Vorfuß · Runde $round/2',
          10,
          'Vorfüße belasten, Fersen leicht schweben lassen. Mit weichen Knien '
              'eine kleine Hüftbeuge ausführen und kontrolliert aufrichten. '
              'Rücken neutral, Bewegungsumfang nur so groß wie gut toleriert.',
        ),
        exercise(
          HovFootWarmup.lifts,
          'HOV C3 · Fußheber · Runde $round/2',
          30,
          'Fersen am Boden lassen, Vorfüße anheben und kontrolliert zur '
              'Innen- und Außenkante bewegen (Inversion/Eversion).',
        ),
        exercise(
          HovFootWarmup.steps,
          'HOV C4 · Seitschritt zum Kreuzschritt · Runde $round/2',
          14,
          'Seit- und Kreuzschritt kontrolliert abwechseln, Fußbelastung bewusst '
              'führen. 14 Wiederholungen insgesamt, wie gezeigt; keine Sprünge. '
              'Etwa 30 s Pause nach der Runde.',
        ),
      ],
      // A prescribed wedge is equipment. Travel mode must not silently invent
      // a no-wedge replacement; show that these holds are deferred in Settings.
      if (!travelMode)
        for (var round = 1; round <= 3; round++) ...[
          exercise(
            HovFootWarmup.holdLeft,
            'HOV D1 · Wadenhalten links · $round/3',
            30,
            'Einbeiniges isometrisches Wadenheben links mit dem verordneten '
                'Keil. Zum Gleichgewicht leicht abstützen, Position wie gezeigt '
                'halten. Danach rechts; jede Seite erhält insgesamt 3 × 30 s.',
            timed: true,
          ),
          exercise(
            HovFootWarmup.holdRight,
            'HOV D1 · Wadenhalten rechts · $round/3',
            30,
            'Einbeiniges isometrisches Wadenheben rechts mit dem verordneten '
                'Keil. Zum Gleichgewicht leicht abstützen, Position wie gezeigt '
                'halten. Links/rechts abwechseln; die andere Seite pausiert.',
            timed: true,
          ),
        ],
    ].where((e) => !excludedTracks.contains(e.trackKey)).toList();
  }
}
