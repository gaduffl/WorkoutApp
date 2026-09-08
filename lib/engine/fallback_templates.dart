import '../models/rule_key.dart';
import '../models/user_settings.dart';

/// §9.6: exactly one fixed string per rule key, EN and DE, shipped with the
/// app. On LLM failure (or timeout > 3s, §9.1) these are concatenated in
/// fired order so the product never blocks on the AI layer.
String fallbackText(FiredRule rule, AppLanguage lang) {
  final p = rule.params;
  String pat(String key) => p[key] ?? rule.pattern ?? '';

  switch (rule.key) {
    case RuleKey.restTimeZero:
      return lang == AppLanguage.de ? 'Ruhetag - heute kein Zeitfenster.' : 'Rest day - no time slot today.';
    case RuleKey.restDoubleRed:
      return lang == AppLanguage.de
          ? 'Zwei RED-Tage in Folge - volle Ruhe (oder ein lockerer 20-30 Min. Spaziergang) empfohlen.'
          : 'Two RED days in a row - full rest (or a light 20-30 min walk) recommended.';
    case RuleKey.norwegian4x4Due:
      return lang == AppLanguage.de
          ? 'Im rollierenden 7-Tage-Fenster fehlt der bevorzugte 4x4-Reiz, daher hat er heute Vorrang.'
          : 'A high-intensity day is due and the preferred 4x4 is still missing from the rolling 7-day window, so it takes priority today.';
    case RuleKey.rehitFallbackDue:
      return lang == AppLanguage.de
          ? 'Das vom CAROL-Bike geführte Preset CAROL REHIT Intense füllt heute einen noch offenen, separaten Hochintensitätstag.'
          : 'The bike-guided CAROL REHIT Intense preset fills one still-due distinct high-intensity day today.';
    case RuleKey.baseLongDeficit:
      return lang == AppLanguage.de
          ? 'Die lange 60-Minuten-Grundlageneinheit fehlt im rollierenden 7-Tage-Fenster.'
          : 'The 60-minute base exposure is missing from the rolling 7-day window.';
    case RuleKey.baseShortDeficit:
      return lang == AppLanguage.de
          ? 'Archivierte Begründung aus einer früheren Zielversion.'
          : 'Archived rationale from an earlier target version.';
    case RuleKey.muscleStimulusDeficit:
      return lang == AppLanguage.de
          ? 'Der Plan schließt den größten wirksamen Satzrückstand bei ${p['muscles'] ?? 'den Zielmuskeln'}.'
          : 'This plan closes the largest effective-set deficit for ${p['muscles'] ?? 'the target muscles'}.';
    case RuleKey.muscleRecoveryDemotion:
      return lang == AppLanguage.de
          ? 'Kürzlich belastete Muskeln wurden niedriger gewichtet, damit die Erholung berücksichtigt bleibt.'
          : 'Recently trained muscles were weighted down to preserve recovery.';
    case RuleKey.muscleOverMaxDemotion:
      return lang == AppLanguage.de
          ? 'Arbeit oberhalb des 7-Tage- oder 28-Tage-Maximums wurde niedriger gewichtet.'
          : 'Work crossing a muscle\'s 7-day or 28-day maximum was weighted down.';
    case RuleKey.recoverySwapEasyCardio:
      return lang == AppLanguage.de
          ? 'Hohe Intensität hat die heutige Erholungs- und Sicherheitsprüfung nicht bestanden; Intervalle wurden im selben Zeitfenster durch lockere kontinuierliche Bewegung ersetzt.'
          : 'High intensity did not pass today\'s recovery and safety gate, so intervals were replaced with easy continuous movement inside the same time window.';
    case RuleKey.easyRecoveryCardio:
      return lang == AppLanguage.de
          ? 'Lockeres kontinuierliches Ausdauertraining passt heute als ermüdungsarme Wahl; kein aktuelles Grundlagendefizit hat die Empfehlung ausgelöst.'
          : 'Easy continuous cardio fits as a low-fatigue choice; no current base-aerobic deficit drove the recommendation.';
    case RuleKey.manualSessionOverride:
      return lang == AppLanguage.de
          ? 'Du hast ${p['session'] ?? 'diese Einheit'} heute bewusst als Alternative gewählt; Zeit- und Sicherheitsanpassungen gelten weiterhin.'
          : 'You explicitly chose ${p['session'] ?? 'this session'} as today\'s alternative; normal time and safety adjustments still apply.';
    case RuleKey.floorForceStrength:
      return lang == AppLanguage.de
          ? 'Kraft liegt hinter dem Wochenziel, daher deckt die heutige Wahl das zuerst ab.'
          : "Strength is behind on the weekly floor, so today's pick covers that first.";
    case RuleKey.floorForceIntensity:
      return lang == AppLanguage.de
          ? 'Intensität liegt hinter dem Wochenziel, daher deckt die heutige Wahl das zuerst ab.'
          : "Intensity is behind on the weekly floor, so today's pick covers that first.";
    case RuleKey.floorSoftBoost:
      return lang == AppLanguage.de
          ? 'Das Wochenziel hinkt etwas hinterher - die heutige Wahl wurde leicht in diese Richtung geschoben.'
          : "The weekly floor is a little behind, so today's pick nudges toward catching up.";
    case RuleKey.legheavyDemoted:
      return lang == AppLanguage.de
          ? 'Gestern war auch beinlastig, daher wurden beinlastige Optionen heute niedriger priorisiert.'
          : 'Yesterday was leg-heavy too, so leg-heavy sessions were deprioritized today.';
    case RuleKey.legheavyBacktobackVolumecut:
      return lang == AppLanguage.de
          ? 'Alle machbaren Optionen waren wieder beinlastig - heute mit reduziertem Volumen (-20%).'
          : 'Every feasible option was leg-heavy again, so today runs at reduced volume (-20%).';
    case RuleKey.recencyBoost:
      return lang == AppLanguage.de
          ? '${pat('pattern')} wurde seit über 5 Tagen nicht trainiert und hatte daher heute Vorrang.'
          : "The ${pat('pattern')} pattern hasn't been trained in over 5 days, so it got priority today.";
    case RuleKey.queueNext:
      return lang == AppLanguage.de ? 'Als Nächstes in der Reihe: ${p['session'] ?? ''}.' : 'Next in queue: ${p['session'] ?? ''}.';
    case RuleKey.s6WeekendRule:
      return lang == AppLanguage.de
          ? 'Wochenende mit freiem 30+ Min. Fenster - Zone 2 steht daher oben.'
          : "It's the weekend with a free 30+ min slot, so Zone 2 moved to the top.";
    case RuleKey.s7TimeSub:
      return lang == AppLanguage.de
          ? '4x4 wurde wegen der Zeit durch das vom CAROL-Bike geführte Preset CAROL REHIT Intense ersetzt.'
          : '4x4 was swapped for the bike-guided CAROL REHIT Intense preset due to time.';
    case RuleKey.s7SecondSessionOffer:
      return lang == AppLanguage.de
          ? 'Seit 48h keine Intensitätseinheit - optional das vom CAROL-Bike geführte Preset CAROL REHIT Intense als zweite Einheit heute.'
          : 'No intensity in the last 48h - optionally add the bike-guided CAROL REHIT Intense preset as a second session today.';
    case RuleKey.yellowVolumeCut:
      return lang == AppLanguage.de
          ? 'Erholung ist mittelmäßig, daher ist das Trainingsvolumen heute reduziert.'
          : 'Recovery is middling, so training volume is reduced today.';
    case RuleKey.yellow4x4ToRehit:
      return lang == AppLanguage.de
          ? 'Erholung ist mittelmäßig, daher ersetzt das vom CAROL-Bike geführte Preset CAROL REHIT Intense heute das 4x4.'
          : 'Recovery is middling, so the bike-guided CAROL REHIT Intense preset replaces the 4x4 today.';
    case RuleKey.redSwapTechnique:
      return lang == AppLanguage.de
          ? 'Erholung ist niedrig - heute als Technik-Einheit: 60% Last, halbe Satzzahl, RIR>=4.'
          : 'Recovery is low - today runs as a technique session: 60% load, half the sets, RIR>=4.';
    case RuleKey.redSwapZ2:
      return lang == AppLanguage.de
          ? 'Erholung ist niedrig - Zone 2 / Mobility ist heute die sichere Wahl.'
          : 'Recovery is low, so Zone 2 / mobility is the safe choice today.';
    case RuleKey.timeCompress60_35:
      return lang == AppLanguage.de
          ? '60 -> 35 Min: Zusatzübungen und/oder das Preset CAROL REHIT Intense als Finisher gestrichen, Hauptsupersätze bleiben.'
          : '60 -> 35 min: accessory work and/or the CAROL REHIT Intense preset finisher dropped, primary supersets kept.';
    case RuleKey.timeCompress35_20:
      return lang == AppLanguage.de
          ? '35 -> 20 Min: nur das aktuell wichtigste Paar, 2 harte Sätze je Übung.'
          : '35 -> 20 min: just the highest-need pair, 2 hard sets each.';
    case RuleKey.travelModeActive:
      return lang == AppLanguage.de
          ? 'Reisemodus ist aktiv: keine Geräte, Fortschritt über Wiederholungen, Tempo oder Bewegungsumfang; die Laststeigerung pausiert.'
          : 'Travel mode is active: no equipment, progress through reps or hold duration, tempo, and range of motion; load progression is paused.';
    case RuleKey.lowerBackRecoveryActive:
      return lang == AppLanguage.de
          ? 'Der Rücken-Recovery-Modus ist aktiv: belastetes Heben und dessen Laststeigerung pausieren; heute gilt nur die konservative Recovery-Dosis.'
          : 'Lower-back recovery mode is active: loaded hinge work and its load progression are paused; only the conservative recovery dose applies today.';
    case RuleKey.lowerBackRecoveryLoadMinimized:
      return lang == AppLanguage.de
          ? 'Der Rücken-Recovery-Modus minimiert die LWS-Last: keine belasteten Squats, ungestützten Rows oder Presses, Zusatzgewichte bei Pull-ups oder belastenden Core-Stufen. Stattdessen gelten gestützte Oberkörperarbeit, Pull-ups ohne Zusatzgewicht und ATG-1/Pump-Arbeit.'
          : 'Lower-back recovery minimizes lumbar loading: no weighted squats, unsupported rows or presses, added pull-up load, or demanding core steps. Supported upper-body work, unweighted pull-ups, and ATG 1 pump work are used instead.';
    case RuleKey.lowerBackRecoverySpacing:
      return lang == AppLanguage.de
          ? 'Recovery-Arbeit ist heute wegen des 48-Stunden-Abstands, der Grenze von zwei Einheiten pro sieben Tage oder des noch offenen Morgen-Feedbacks nicht fällig; Heben bleibt ersetzt.'
          : 'Recovery work is not due today because of the 48-hour spacing, two-per-seven-day cap, or pending morning feedback; hinge work stays replaced.';
    case RuleKey.lowerBackRecoveryReentry:
      return lang == AppLanguage.de
          ? 'Die symptomgesteuerten Kriterien erlauben einen vorsichtigen Heben-Wiedereinstieg mit 50% und erhöhtem Start; heute keine Laststeigerung.'
          : 'Symptom-gated criteria opened a graded elevated-start deadlift re-entry at 50%; no load increase today.';
    case RuleKey.painSubMild:
      return lang == AppLanguage.de
          ? '${pat('pattern')}: leichter Schmerz - Last reduziert und Bewegungsradius angepasst.'
          : "${pat('pattern')} pain is mild - load eased back and reduced ROM used today.";
    case RuleKey.painSubSharp:
      return lang == AppLanguage.de
          ? '${pat('pattern')}: Starker Schmerz hat die feste Schmerzregel aktiviert; die übliche Bewegung oder Einheit wurde angepasst, ersetzt oder entfernt.'
          : '${pat('pattern')}: Sharp pain activated the fixed pain rule; the usual movement or session was modified, replaced, or removed.';
    case RuleKey.painFreeze:
      return lang == AppLanguage.de
          ? '${pat('pattern')}: Fortschritt pausiert, solange Schmerz gemeldet ist.'
          : "${pat('pattern')} progression is frozen while pain is flagged.";
    case RuleKey.painMedicalEscalation:
      return lang == AppLanguage.de
          ? 'Betroffene Bewegung stoppen und vor der Wiederaufnahme eine qualifizierte medizinische Abklärung suchen.'
          : 'Stop the affected movement and seek a qualified medical assessment before resuming it.';
    case RuleKey.urgentMedicalAssessment:
      return lang == AppLanguage.de
          ? 'Heute nicht trainieren. Neue Schwäche sowie Taubheit im Sattelbereich oder Blasen-/Darmveränderungen brauchen eine dringende medizinische Abklärung.'
          : 'Do not train today. New weakness, saddle-area numbness, or bladder/bowel changes need urgent medical assessment.';
    case RuleKey.painReentryTest:
      return lang == AppLanguage.de
          ? '${pat('pattern')}: seit 2 Einheiten gemeldet - heute ein leichter Test (50% x 8).'
          : "${pat('pattern')} pain has held for 2 sessions - today offers a light test set (50% x 8).";
    case RuleKey.deloadActive:
      return lang == AppLanguage.de
          ? '${pat('pattern')} ist in geplantem Deload - leichtere Last, weniger Sätze, RIR>=4.'
          : "${pat('pattern')} is in a scheduled deload - lighter load, fewer sets, RIR>=4.";
    case RuleKey.detrainAdjust:
      return lang == AppLanguage.de
          ? '${pat('pattern')} war länger pausiert und startet daher mit reduzierter Last.'
          : "${pat('pattern')} hasn't been trained in a while, so it resumes at a reduced load.";
    case RuleKey.capLadderJump:
      return lang == AppLanguage.de
          ? '${pat('pattern')} hat die Kurzhantel-Obergrenze erreicht - nächste Leiterstufe, leichtere Last.'
          : "${pat('pattern')} hit the dumbbell ceiling - moving to the next ladder step at a lighter load.";
    case RuleKey.onboardSubstitute:
      return lang == AppLanguage.de
          ? 'Die Ersatzübung startet bewusst leicht - kein Rückschritt, sondern ein sanfter Einstieg.'
          : "The substitute exercise starts light on purpose - it's a deliberately easy re-entry, not a step back.";
    case RuleKey.illnessGuard:
      return lang == AppLanguage.de
          ? 'HRV und Ruhepuls deuten auf eine mögliche beginnende Erkrankung hin - ein voller Ruhetag ist sinnvoll.'
          : 'HRV and resting heart rate both point to possible incoming illness - consider a full rest day.';
    case RuleKey.subjOverrideDown:
      return lang == AppLanguage.de
          ? 'Du hast dich heute schlecht gefühlt, daher wurde unabhängig von den Zahlen nach unten korrigiert.'
          : 'You reported feeling rough today, so the plan was capped down regardless of the numbers.';
    case RuleKey.subjOverrideUpBlocked:
      return lang == AppLanguage.de
          ? 'Du hast dich gut gefühlt, aber anhaltend niedrige HRV hat das Hochstufen verhindert.'
          : 'You felt good today, but persistent low HRV blocked the upgrade to a full session.';
  }
}
