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
          ? '4x4 wurde wegen der Zeit durch ein 8-Minuten-REHIT ersetzt.'
          : '4x4 swapped for an 8-min REHIT due to time.';
    case RuleKey.s7SecondSessionOffer:
      return lang == AppLanguage.de
          ? 'Seit 48h keine Intensitätseinheit - optional ein 8-Minuten-REHIT als zweite Einheit heute.'
          : 'No intensity in the last 48h - add an 8-min REHIT as a second session today.';
    case RuleKey.yellowVolumeCut:
      return lang == AppLanguage.de
          ? 'Erholung ist mittelmäßig, daher heute rund 25% weniger Arbeitssätze.'
          : 'Recovery is middling, so work sets are cut about 25% today.';
    case RuleKey.yellow4x4ToRehit:
      return lang == AppLanguage.de
          ? 'Erholung ist mittelmäßig, daher ersetzt ein 8-Minuten-REHIT das 4x4 heute.'
          : 'Recovery is middling, so an 8-min REHIT replaces the 4x4 today.';
    case RuleKey.redSwapTechnique:
      return lang == AppLanguage.de
          ? 'Erholung ist niedrig - heute als Technik-Einheit: 60% Last, halbe Satzzahl, RIR>=4.'
          : 'Recovery is low - today runs as a technique session: 60% load, half the sets, RIR>=4.';
    case RuleKey.redSwapZ2:
      return lang == AppLanguage.de
          ? 'Erholung ist niedrig - Intensität wurde durch Zone 2 / Mobility ersetzt.'
          : 'Recovery is low - intensity work swapped for Zone 2 / mobility instead.';
    case RuleKey.timeCompress60_35:
      return lang == AppLanguage.de
          ? '60 -> 35 Min: Zusatzübungen und/oder REHIT-Finisher gestrichen, Hauptsupersätze bleiben.'
          : '60 -> 35 min: accessory work and/or the REHIT finisher dropped, primary supersets kept.';
    case RuleKey.timeCompress35_20:
      return lang == AppLanguage.de
          ? '35 -> 20 Min: nur das erste Supersatz-Paar, 2 harte Sätze je Übung.'
          : '35 -> 20 min: just the first superset pair, 2 hard sets each.';
    case RuleKey.painSubMild:
      return lang == AppLanguage.de
          ? '${pat('pattern')}: leichter Schmerz - Last reduziert und Bewegungsradius angepasst.'
          : "${pat('pattern')} pain is mild - load eased back and reduced ROM used today.";
    case RuleKey.painSubSharp:
      return lang == AppLanguage.de
          ? '${pat('pattern')}: starker Schmerz - ${p['substitute'] ?? 'Ersatzübung'} statt der üblichen Übung, bewusst leicht.'
          : "${pat('pattern')} pain is sharp - ${p['substitute'] ?? 'a substitute'} used instead, with lighter, pain-free loading.";
    case RuleKey.painFreeze:
      return lang == AppLanguage.de
          ? '${pat('pattern')}: Fortschritt pausiert, solange Schmerz gemeldet ist.'
          : "${pat('pattern')} progression is frozen while pain is flagged.";
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
