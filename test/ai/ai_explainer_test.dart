import 'package:flutter_test/flutter_test.dart';
import 'package:morningcoach/ai/ai_explainer.dart';
import 'package:morningcoach/engine/fallback_templates.dart';
import 'package:morningcoach/models/check_in.dart';
import 'package:morningcoach/models/decision_trace.dart';
import 'package:morningcoach/models/rule_key.dart';
import 'package:morningcoach/models/session_type.dart';
import 'package:morningcoach/models/user_settings.dart';

void main() {
  final today = DateTime(2026, 1, 20);
  const explainer = AiExplainer();

  DecisionTrace buildTrace() => DecisionTrace(
        date: today,
        checkin: CheckIn(date: today, timeMinutes: 0, subjective: 3, timestamp: today),
        recovery: const RecoveryTrace(
          hrvZToday: null,
          hrvTrend3: null,
          sleepScore: null,
          rhrDev: null,
          bucket: ReadinessBucket.green,
          compositeScore: 70,
        ),
        candidates: const [],
        firedRules: const [FiredRule(RuleKey.restTimeZero)],
        plan: null,
        restReason: 'Rest day',
        queue: const QueueTraceInfo(pointerBefore: SessionTypeId.s1, servedBefore: {}),
      );

  test('with no API key, returns the deterministic fallback regardless of the toggle', () async {
    final trace = buildTrace();
    final expected = fallbackText(const FiredRule(RuleKey.restTimeZero), AppLanguage.en);

    final onText = await explainer.dailyExplanation(trace, const UserSettings(aiExplanationsEnabled: true));
    final offText = await explainer.dailyExplanation(trace, const UserSettings(aiExplanationsEnabled: false));

    expect(onText, expected);
    expect(offText, expected);
  });

  test('toggle off short-circuits before any API key check', () async {
    final trace = buildTrace();
    final settings = const UserSettings(aiExplanationsEnabled: false).copyWith(anthropicApiKey: 'sk-fake-not-a-real-key');

    final text = await explainer.dailyExplanation(trace, settings);

    expect(text, fallbackText(const FiredRule(RuleKey.restTimeZero), AppLanguage.en));
  });
}
