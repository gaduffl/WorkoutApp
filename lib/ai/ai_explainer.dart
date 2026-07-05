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

  String _glossary(RuleKey key) {
    switch (key) {
      case RuleKey.restTimeZero:
        return 'no time slot today';
      case RuleKey.restDoubleRed:
        return 'second RED recovery day in a row';
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
        return 'not enough time for the 4x4, so REHIT substituted';
      case RuleKey.s7SecondSessionOffer:
        return 'no intensity work in 48h, REHIT offered as a bonus second session';
      case RuleKey.yellowVolumeCut:
        return 'recovery is middling, sets cut about 25%';
      case RuleKey.yellow4x4ToRehit:
        return 'recovery is middling, 4x4 swapped for REHIT';
      case RuleKey.redSwapTechnique:
        return 'recovery is low, running a light technique session instead';
      case RuleKey.redSwapZ2:
        return 'recovery is low, intensity swapped for Zone 2 / mobility';
      case RuleKey.timeCompress60_35:
        return 'compressed from 60 to 35 minutes';
      case RuleKey.timeCompress35_20:
        return 'compressed to a 20-minute first-superset-only session';
      case RuleKey.painSubMild:
        return 'mild pain flagged on this pattern, load/ROM eased back';
      case RuleKey.painSubSharp:
        return 'sharp pain flagged, exercise substituted for a pain-free one';
      case RuleKey.painFreeze:
        return 'progression paused on this pattern while pain is flagged';
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
    final rules = trace.firedRules.isEmpty
        ? [FiredRule(RuleKey.queueNext, params: {'session': trace.plan!.sessionName})]
        : trace.firedRules;
    return rules.map((r) => fallbackText(r, lang)).join(' ');
  }

  String _painAdvisory(DecisionTrace trace) {
    if (trace.checkin.pain.isEmpty) return '';
    return ' If pain persists beyond a week, or you notice radiating pain, numbness, or tingling, '
        'please consult a medical professional before continuing to train the affected area.';
  }

  Future<String> dailyExplanation(DecisionTrace trace, UserSettings settings) async {
    final fallback = _fallbackConcat(trace, settings.language) + _painAdvisory(trace);
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
    final glossaryLines = trace.firedRules.map((r) => '- ${r.code}: ${_glossary(r.key)}').join('\n');
    final langName = settings.language == AppLanguage.de ? 'German' : 'English';
    final planLine = trace.plan == null
        ? 'Outcome: ${trace.restReason ?? "rest day"}.'
        : 'Plan: ${trace.plan!.sessionName} (${trace.plan!.tier.name} tier), '
            '${trace.plan!.exercises.map((e) => '${e.name} ${e.sets}x${e.repRange.$1}-${e.repRange.$2}').join(', ')}.';

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
