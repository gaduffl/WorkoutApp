import 'dart:convert';

import 'package:http/http.dart' as http;

import '../engine/fallback_templates.dart';
import '../models/decision_trace.dart';
import '../models/rule_key.dart';
import '../models/user_settings.dart';

/// §9: the AI layer never decides - it only narrates a frozen DecisionTrace.
/// On any failure, timeout (>3s, §9.1), or missing API key, callers get the
/// deterministic fallback-template concatenation instead, so the app never
/// blocks on the LLM.
class AiExplainer {
  const AiExplainer();

  static const _model = 'claude-haiku-4-5-20251001';
  static const _endpoint = 'https://api.anthropic.com/v1/messages';

  String _glossary(FiredRule rule) {
    final key = rule.key;
    switch (key) {
      case RuleKey.restTimeZero:
        return 'no time slot today';
      case RuleKey.restDoubleRed:
        return 'second RED recovery day in a row';
      case RuleKey.norwegian4x4Due:
        return 'a high-intensity day is due and the preferred 4x4 is missing from the rolling 7-day window';
      case RuleKey.rehitFallbackDue:
        return 'the bike-guided CAROL REHIT Intense preset fills one still-due distinct high-intensity day';
      case RuleKey.baseLongDeficit:
        return 'the allocated 60-minute base exposure is missing';
      case RuleKey.baseShortDeficit:
        return 'an archived rationale from an earlier target version';
      case RuleKey.muscleStimulusDeficit:
        return 'projected explicit muscle credit closes weekly and 28-day effective-set deficits';
      case RuleKey.muscleRecoveryDemotion:
        return 'muscles trained today or yesterday were demoted for recovery';
      case RuleKey.muscleOverMaxDemotion:
        return 'projected work crossing a muscle\'s 7-day or 28-day maximum was penalized';
      case RuleKey.recoverySwapEasyCardio:
        return 'high intensity did not pass today\'s recovery and safety gate, so it was replaced by easy continuous movement in the same time window';
      case RuleKey.easyRecoveryCardio:
        return 'easy continuous cardio fits as a low-fatigue choice; no current base-aerobic deficit drove the recommendation';
      case RuleKey.manualSessionOverride:
        return 'the user explicitly selected ${rule.params['session'] ?? 'today\'s alternative'}; normal time and safety adjustments still apply';
      case RuleKey.floorForceStrength:
        return 'weekly strength floor is behind and about to age out';
      case RuleKey.floorForceIntensity:
        return 'weekly intensity floor is behind and about to age out';
      case RuleKey.floorSoftBoost:
        return 'weekly floor is a little behind, not urgent yet';
      case RuleKey.legheavyDemoted:
        return 'yesterday was leg-heavy too, so leg work was deprioritized';
      case RuleKey.legheavyBacktobackVolumecut:
        return 'every option was leg-heavy again, so volume was cut 20%';
      case RuleKey.recencyBoost:
        return 'this pattern has not been trained in over 5 days';
      case RuleKey.queueNext:
        return 'next session in the rotating queue';
      case RuleKey.s6WeekendRule:
        return 'weekend with a free slot, Zone 2 prioritized';
      case RuleKey.s7TimeSub:
        return 'not enough time for the 4x4, so the bike-guided CAROL REHIT Intense preset was substituted';
      case RuleKey.s7SecondSessionOffer:
        return 'no intensity work in 48h, so the bike-guided CAROL REHIT Intense preset was offered as a bonus second session';
      case RuleKey.yellowVolumeCut:
        return 'recovery is middling, so training volume was reduced';
      case RuleKey.yellow4x4ToRehit:
        return 'recovery is middling, so 4x4 was swapped for the bike-guided CAROL REHIT Intense preset';
      case RuleKey.redSwapTechnique:
        return 'recovery is low, running a light technique session instead';
      case RuleKey.redSwapZ2:
        return 'recovery is low, so Zone 2 / mobility is the safe choice';
      case RuleKey.timeCompress60_35:
        return 'compressed from 60 to 35 minutes';
      case RuleKey.timeCompress35_20:
        return 'compressed to the highest-need pair that fits 20 minutes';
      case RuleKey.travelModeActive:
        return 'no-equipment travel mode active; use reps or hold duration, tempo, and range of motion while load progression stays paused';
      case RuleKey.lowerBackRecoveryActive:
        return 'dedicated lower-back recovery mode is active; loaded hinge work and load progression stay paused';
      case RuleKey.lowerBackRecoveryLoadMinimized:
        return 'lower-back recovery uses a load-minimized strength catalogue: symptom-gated back extensions, unweighted pull-ups, supported presses/rows, and ATG 1 pump work replace weighted squats, unsupported trunk loading, loaded pull-ups, and demanding core variants';
      case RuleKey.lowerBackRecoverySpacing:
        return 'recovery exposure is not due under its spacing, frequency, and next-morning-response gates; hinge work remains replaced';
      case RuleKey.lowerBackRecoveryReentry:
        return 'symptom-gated graded elevated-start deadlift re-entry at 50% with no load increase';
      case RuleKey.painSubMild:
        return 'mild pain flagged on this pattern, load/ROM eased back';
      case RuleKey.painSubSharp:
        return 'sharp pain activated the deterministic pain rule, so the usual movement or session was modified, replaced, or removed';
      case RuleKey.painFreeze:
        return 'progression paused on this pattern while pain is flagged';
      case RuleKey.painMedicalEscalation:
        return 'fixed safety instruction: stop the affected movement and seek qualified medical assessment before resuming';
      case RuleKey.urgentMedicalAssessment:
        return 'fixed urgent safety instruction: do not train and seek urgent medical assessment for neurological warning signs';
      case RuleKey.painReentryTest:
        return 'offering a light 50% x 8 test to check pain-free readiness';
      case RuleKey.deloadActive:
        return 'scheduled deload in progress on this pattern';
      case RuleKey.detrainAdjust:
        return 'pattern untrained for a while, resuming at reduced load';
      case RuleKey.capLadderJump:
        return 'hit the dumbbell ceiling, moving up the exercise ladder instead';
      case RuleKey.onboardSubstitute:
        return 'substitute exercise deliberately starts light';
      case RuleKey.illnessGuard:
        return 'HRV and resting heart rate suggest possible incoming illness';
      case RuleKey.subjOverrideDown:
        return 'user self-rated feeling rough, overriding the numbers downward';
      case RuleKey.subjOverrideUpBlocked:
        return 'user felt good, but persistent low HRV blocked an upgrade';
    }
  }

  String _fallbackConcat(DecisionTrace trace, AppLanguage lang) {
    if (trace.plan == null) {
      return trace.firedRules.map((r) => fallbackText(r, lang)).join(' ');
    }
    if (trace.firedRules.isEmpty) {
      // Old saved traces can predate explicit selection rationales. Do not
      // fabricate queue membership merely to fill the narration surface.
      return lang == AppLanguage.de
          ? 'Für diesen gespeicherten Plan wurde kein Entscheidungsgrund aufgezeichnet.'
          : 'No decision rationale was recorded for this saved plan.';
    }
    return trace.firedRules.map((r) => fallbackText(r, lang)).join(' ');
  }

  String _painAdvisory(DecisionTrace trace) {
    if (trace.checkin.pain.isEmpty) return '';
    return ' If pain persists beyond a week, or you notice radiating pain, numbness, or tingling, '
        'please consult a medical professional before continuing to train the affected area.';
  }

  Future<String> dailyExplanation(DecisionTrace trace, UserSettings settings) async {
    // Safety escalation text is a fixed product rule, not narration. Return
    // it verbatim and never send it through the model where it could be
    // softened, paraphrased, or obscured by other rationale.
    final medicalEscalation = trace.firedRules.where(
      (rule) =>
          rule.key == RuleKey.urgentMedicalAssessment ||
          rule.key == RuleKey.painMedicalEscalation,
    );
    if (medicalEscalation.isNotEmpty) {
      return fallbackText(medicalEscalation.first, settings.language);
    }
    final fallback = _fallbackConcat(trace, settings.language) + _painAdvisory(trace);
    if (!settings.aiExplanationsEnabled) return fallback;
    final apiKey = settings.anthropicApiKey;
    if (apiKey == null || apiKey.isEmpty) return fallback;

    try {
      final text = await _callApi(trace, settings, apiKey).timeout(const Duration(seconds: 3));
      if (text == null || text.trim().isEmpty) return fallback;
      return text.trim() + _painAdvisory(trace);
    } catch (_) {
      return fallback;
    }
  }

  Future<String?> _callApi(DecisionTrace trace, UserSettings settings, String apiKey) async {
    final glossaryLines = trace.firedRules
        .map((rule) => '- ${rule.code}: ${_glossary(rule)}')
        .join('\n');
    final langName = settings.language == AppLanguage.de ? 'German' : 'English';
    final planLine = trace.plan == null
        ? 'Outcome: ${trace.restReason ?? "rest day"}.'
        : 'Plan: ${trace.plan!.sessionName} (${trace.plan!.tier.name} tier), '
            '${trace.plan!.exercises.map((e) => '${e.name} ${e.sets}x${e.targetLabel}').join(', ')}.';

    final prompt = '''
You are the "why" narrator for a deterministic workout-recommendation engine. You never decide anything - you only explain, in $langName, why today's plan is what it is.

Readiness: bucket=${trace.recovery.bucket.name}, subjective=${trace.checkin.subjective}/5, composite=${trace.recovery.compositeScore.toStringAsFixed(0)}.
$planLine

Rules that fired today (glossary - reference ONLY these, do not invent reasons):
$glossaryLines

Write <=70 words, plain language, no medical claims, no emojis. Tone: ${settings.aiTone}.
''';

    final response = await http.post(
      Uri.parse(_endpoint),
      headers: {
        'content-type': 'application/json',
        'x-api-key': apiKey,
        'anthropic-version': '2023-06-01',
      },
      body: jsonEncode({
        'model': _model,
        'max_tokens': 200,
        'messages': [
          {'role': 'user', 'content': prompt},
        ],
      }),
    );

    if (response.statusCode != 200) return null;
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final content = body['content'] as List?;
    if (content == null || content.isEmpty) return null;
    return (content.first as Map<String, dynamic>)['text'] as String?;
  }
}
