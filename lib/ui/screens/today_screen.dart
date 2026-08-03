import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../ai/ai_explainer.dart';
import '../../engine/cardio_engine.dart';
import '../../engine/rest_day_rehit_engine.dart';
import '../../engine/schedule_fit_engine.dart';
import '../../engine/session_templates.dart';
import '../../models/decision_trace.dart';
import '../../models/plan.dart';
import '../../models/rule_key.dart';
import '../../models/session_type.dart';
import '../../state/app_controller.dart';
import '../widgets/cardio_widgets.dart';
import '../widgets/progression_panel.dart';
import 'checkin_screen.dart';
import 'logger_screen.dart';

/// Reorders a plan's exercises to match Logger execution order.
///
/// Warm-ups are collected before their superset group or standalone work
/// exercise, so the Today preview matches the actual step sequence.
List<PlannedExercise> _playOrder(List<PlannedExercise> exercises) {
  // Group warm-ups with the work exercise they precede.
  final units = <({int workIdx, List<int> warmups, int? group})>[];
  final pending = <int>[];
  for (var i = 0; i < exercises.length; i++) {
    if (exercises[i].isWarmup) {
      pending.add(i);
    } else {
      units.add((workIdx: i, warmups: List.of(pending), group: exercises[i].supersetGroup));
      pending.clear();
    }
  }

  final ordered = <PlannedExercise>[];
  var u = 0;
  while (u < units.length) {
    final unit = units[u];
    if (unit.group != null) {
      // Superset: collect all warm-ups for the group first.
      final group = [unit];
      var v = u + 1;
      while (v < units.length && units[v].group == unit.group) {
        group.add(units[v]);
        v++;
      }
      for (final m in group) {
        for (final w in m.warmups) {
          ordered.add(exercises[w]);
        }
      }
      for (final m in group) {
        ordered.add(exercises[m.workIdx]);
      }
      u = v;
    } else {
      for (final w in unit.warmups) {
        ordered.add(exercises[w]);
      }
      ordered.add(exercises[unit.workIdx]);
      u++;
    }
  }
  return ordered;
}

const optionalRehitFinisherMessage =
    'Optional finisher: CAROL REHIT Intense after the strength work. Complete the bike-guided preset; both sprints earn intensity credit.';

String planTimingLabel(SessionPlan plan) => switch (plan.sessionId) {
      SessionTypeId.s3 => 'CAROL bike preset · 30 min',
      SessionTypeId.s7 => 'CAROL bike preset · 08:40',
      // A natively-60-min session squeezed into a shorter window must not
      // call itself a "full tier" — that is exactly what it is not.
      _ => plan.timeCompressed
          ? 'compressed to fit - ~${plan.estimatedDurationMin} min'
          : '${plan.tier.name} tier - ~${plan.estimatedDurationMin} min',
    };

String candidateTimingLabel(
  SessionTypeId sessionId,
  String reason,
) => switch (sessionId) {
      SessionTypeId.s3 => 'CAROL 30-minute preset · $reason',
      SessionTypeId.s7 => 'CAROL preset (08:40) · $reason',
      _ => reason,
    };

/// Mirrors the logger's finisher dialog gate exactly, so Today never
/// promises a finisher that the completed plan cannot actually offer.
String? optionalRehitFinisherHint(
  SessionPlan? plan, {
  required bool safetyEligible,
}) {
  if (!safetyEligible) return null;
  if (plan == null || plan.tier != SessionTier.extended) return null;
  if (!plan.optionalRehitFinisherReserved) return null;
  if (sessionTemplates[plan.sessionId]?.hasOptionalRehitFinisher != true) return null;
  return optionalRehitFinisherMessage;
}

/// A short, honest reason a candidate ranked where it did, drawn from the
/// same score terms the engine used rather than invented by the UI.
String candidateReason(ScoredCandidate candidate) {
  final terms = candidate.scoreTerms;
  if (terms.containsKey(painNoSafeWorkScoreTerm)) {
    return 'Unavailable - no pain-safe work remains';
  }
  if (terms.containsKey('norwegian4x4Due')) {
    return 'Prioritizes the preferred 4×4 while a high-intensity day is due';
  }
  if (terms.containsKey('rehitFallbackDue')) {
    return 'Fills a due rolling high-intensity day with REHIT';
  }
  if (terms.containsKey('baseLongDeficit')) {
    return 'Fills the long base-aerobic exposure';
  }
  if (terms.containsKey('muscleWeeklyDeficit') ||
      terms.containsKey('muscle28dMinimumDeficit') ||
      terms.containsKey('muscle28dCenterDeficit')) {
    return 'Targets your largest effective-set deficits';
  }
  if (terms.containsKey('surplusIntensitySuppressed')) {
    return 'Extra intensity is not needed now';
  }
  if (terms.containsKey('muscleOverMaxDemotion')) {
    return 'Deprioritized - projected work crosses a 7-day or 28-day maximum';
  }
  if (terms.containsKey('muscleRecoveryDemotion')) {
    return 'Deprioritized - target muscles need recovery';
  }
  if (candidate.sessionId == SessionTypeId.s6) {
    return 'Easy recovery cardio that fits today\'s available time';
  }
  // Legacy v1 traces remain readable after the engine upgrade.
  if (terms.containsKey('floorForceStrength') ||
      terms.containsKey('floorForceIntensity')) {
    return 'Would catch up your weekly floor';
  }
  if (terms.containsKey('floorSoftBoost')) {
    return 'Slightly behind on your weekly floor';
  }
  if (terms.containsKey('legHeavyDemoted')) {
    return 'Deprioritized - legs were worked yesterday';
  }
  if (terms.containsKey('recencyBoost')) {
    return "Covers a pattern you haven't trained in a while";
  }
  if (terms.containsKey('weekendPriority')) {
    return 'Prioritized for your weekend schedule';
  }
  return 'Next up in your rotation';
}

/// One line describing when the rest-day REHIT would fit, claiming a learned
/// habit only when the slot really came from training history.
String restDayRehitSlotLine(RestDayRehitResult result) {
  final at = result.suggestedNudgeTime;
  if (at == null) return 'A short bike session would still fit today.';
  final clock = '${at.hour.toString().padLeft(2, '0')}:'
      '${at.minute.toString().padLeft(2, '0')}';
  return switch (result.slotSource) {
    ScheduleSlotSource.weekdayHabit ||
    ScheduleSlotSource.overallHabit =>
      'Around $clock fits the time you usually train.',
    _ => 'There is still room for it around $clock.',
  };
}

/// Fully pain-blocked strength candidates remain in the trace for audit, but
/// offering one as a tappable swap is misleading because the hard safety gate
/// must redirect it. A partially surviving candidate has no such term and
/// remains available.
bool isPainSafeAlternative(ScoredCandidate candidate) =>
    !candidate.scoreTerms.containsKey(painNoSafeWorkScoreTerm);

class TodayScreen extends StatefulWidget {
  final DecisionTrace trace;

  const TodayScreen({super.key, required this.trace});

  @override
  State<TodayScreen> createState() => _TodayScreenState();
}

class _TodayScreenState extends State<TodayScreen> {
  late DecisionTrace _trace;
  late Future<String> _explanation;
  SessionTypeId? _swapping;
  bool _loggingCardio = false;
  bool _changingTravelMode = false;

  @override
  void initState() {
    super.initState();
    _trace = widget.trace;
    _loadExplanation();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final refreshed = Provider.of<AppController>(context).todayTrace;
    if (refreshed != null &&
        _sameDate(refreshed.date, _trace.date) &&
        !identical(refreshed, _trace)) {
      // Settings changes and manual deloads recompute the controller trace
      // while this route can remain mounted. Adopt that authoritative result;
      // local swaps are preserved because swapToSession updates the same
      // controller trace before returning it here.
      _trace = refreshed;
      _loadExplanation();
    }
  }

  void _loadExplanation() {
    final controller = context.read<AppController>();
    _explanation = const AiExplainer().dailyExplanation(_trace, controller.settings);
  }

  Future<void> _swapTo(SessionTypeId sessionId) async {
    setState(() => _swapping = sessionId);
    final controller = context.read<AppController>();
    try {
      final newTrace = await controller.swapToSession(sessionId);
      if (!mounted) return;
      setState(() {
        _trace = newTrace;
        _swapping = null;
        _loadExplanation();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _swapping = null);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not switch sessions: $e')));
    }
  }

  Future<void> _toggleTravelMode() async {
    if (_changingTravelMode) return;
    final controller = context.read<AppController>();
    final enabled = !controller.settings.travelMode;
    setState(() => _changingTravelMode = true);
    try {
      final refreshed = await controller.setTravelMode(enabled);
      if (!mounted) return;
      setState(() {
        if (refreshed != null) _trace = refreshed;
        _changingTravelMode = false;
        _loadExplanation();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(enabled ? 'Travel mode enabled — plan updated' : 'Travel mode disabled — plan updated')),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _changingTravelMode = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not change travel mode: $error')),
      );
    }
  }

  SessionTypeId _effectiveAlternativeId(DecisionTrace trace, SessionTypeId sourceId) {
    final safetySwap = trace.firedRuleCodes
        .contains(RuleKey.recoverySwapEasyCardio.code());
    if ((trace.recovery.bucket != ReadinessBucket.green || safetySwap) &&
        (sourceId == SessionTypeId.s3 || sourceId == SessionTypeId.s7)) {
      return SessionTypeId.s6;
    }
    if (sourceId == SessionTypeId.s3 &&
        trace.checkin.timeMinutes < 35) {
      return SessionTypeId.s7;
    }
    return sourceId;
  }

  Future<void> _logCardio(
    SessionTypeId id, {
    SessionPlan? plan,
  }) async {
    if (_loggingCardio) return;
    final controller = context.read<AppController>();
    final prescription = const CardioEngine().resolvePrescription(
      sessionId: id,
      persistedPrescription: plan?.cardioPrescription,
      durationMinutes:
          plan?.estimatedDurationMin ?? sessionTypes[id]!.fullDurationMin,
      heartRateMaxBpm: controller.settings.hrMax,
    );
    final completion = await showCardioCompletionDialog(
      context,
      prescription: prescription,
      title: id == SessionTypeId.s7 && plan == null
          ? 'Log second CAROL REHIT Intense attempt'
          : 'Log ${sessionTypes[id]!.name} attempt',
    );
    if (completion == null || !mounted) return;
    setState(() => _loggingCardio = true);
    try {
      await controller.logCardioSession(
        id,
        completion: completion,
        plan: plan,
      );
      if (!mounted) return;
      final completedAsPrescribed =
          completion.completesPrescription(prescription);
      final message = completion.meetsCreditableDose
          ? '${sessionTypes[id]!.name} dose logged ✓'
          : id == SessionTypeId.s6 && completedAsPrescribed
              ? 'Recovery session completed ✓ — no base-aerobic credit'
              : '${sessionTypes[id]!.name} attempt saved — below the qualifying training dose';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not log cardio: $e')));
    } finally {
      if (mounted) setState(() => _loggingCardio = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    final trace = _trace;
    final restoredPlan = trace.plan;
    final staleHighIntensityPlan = restoredPlan != null &&
        !controller.isPlanUsableNow(restoredPlan);
    final plan = staleHighIntensityPlan ? null : restoredPlan;
    final done = controller.sessionDoneToday;
    final loggingStarted = controller.sessionLoggedToday;
    final finisherHint = loggingStarted
        ? null
        : optionalRehitFinisherHint(
            plan,
            safetyEligible:
                controller.rehitFinisherPreviewEligibility(plan).eligible,
          );
    final primaryCardioPrescription = () {
      if (plan == null ||
          sessionTemplates[plan.sessionId]?.isCardioOnly != true) {
        return null;
      }
      return const CardioEngine().resolvePrescription(
        sessionId: plan.sessionId,
        persistedPrescription: plan.cardioPrescription,
        durationMinutes: plan.estimatedDurationMin,
        heartRateMaxBpm: controller.settings.hrMax,
      );
    }();
    final secondRehitEligibility = controller.secondRehitEligibility;
    final secondRehitPrescription = secondRehitEligibility.eligible
        ? const CardioEngine().prescriptionFor(
            sessionId: SessionTypeId.s7,
            durationMinutes:
                sessionTypes[SessionTypeId.s7]!.fullDurationMin,
            heartRateMaxBpm: controller.settings.hrMax,
          )
        : null;
    // The rest-day offer is the in-app half of the same reminder the push
    // nudge sends. It appears only while today is genuinely unused, and never
    // beside a plan that is already the same short bike session.
    final restDayRehit = controller.restDayRehitEligibilityAt(DateTime.now());
    final restDayRehitPrescription = restDayRehit.eligible &&
            !restDayRehit.checkInMissing &&
            secondRehitPrescription == null &&
            plan?.sessionId != SessionTypeId.s7 &&
            plan?.sessionId != SessionTypeId.s3
        ? const CardioEngine().prescriptionFor(
            sessionId: SessionTypeId.s7,
            durationMinutes:
                sessionTypes[SessionTypeId.s7]!.fullDurationMin,
            heartRateMaxBpm: controller.settings.hrMax,
          )
        : null;
    final noOpAlternativeIds = <SessionTypeId>{if (plan != null) plan.sessionId};
    final firedCodes = trace.firedRuleCodes.toSet();
    if (firedCodes.contains('S7_TIME_SUB') || firedCodes.contains('YELLOW_4X4_TO_REHIT')) {
      noOpAlternativeIds.add(SessionTypeId.s3);
    }
    if (firedCodes.contains('RED_SWAP_Z2') ||
        firedCodes.contains('RECOVERY_SWAP_EASY_CARDIO')) {
      noOpAlternativeIds.addAll(const {SessionTypeId.s3, SessionTypeId.s7});
    }
    final sharpHipPain =
        controller.hasActiveSharpHipPain(trace.checkin.pain);
    final seenEffectiveAlternatives = <SessionTypeId>{};
    final alternatives = plan == null
        ? <ScoredCandidate>[]
        : trace.candidates
            .where(isPainSafeAlternative)
            // Defense in depth for restored legacy traces: no-equipment
            // travel plans must never expose CAROL-only swaps.
            .where((c) =>
                !(controller.settings.travelMode || plan.travelMode) ||
                (c.sessionId != SessionTypeId.s3 &&
                    c.sessionId != SessionTypeId.s7))
            .where((c) =>
                controller.isHighIntensityUsableNow() ||
                (c.sessionId != SessionTypeId.s3 &&
                    c.sessionId != SessionTypeId.s7))
            .where((c) => !noOpAlternativeIds.contains(c.sessionId))
            .where((c) => !sharpHipPain || sessionTypes[c.sessionId]?.legHeavy != true)
            .where((c) => seenEffectiveAlternatives.add(_effectiveAlternativeId(trace, c.sessionId)))
            .take(2)
            .toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Today'),
        actions: [
          IconButton(
            icon: _changingTravelMode
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    controller.settings.travelMode ? Icons.luggage : Icons.luggage_outlined,
                    color: controller.settings.travelMode ? Theme.of(context).colorScheme.primary : null,
                  ),
            tooltip: controller.settings.travelMode ? 'End travel mode' : 'Start travel mode',
            onPressed: _changingTravelMode || loggingStarted ? null : _toggleTravelMode,
          ),
          IconButton(
            icon: const Icon(Icons.restart_alt),
            tooltip: 'Redo check-in',
            onPressed:
                loggingStarted ? null : () => _confirmResetToday(context),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (!done) Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _ReadinessBadge(bucket: trace.recovery.bucket, score: trace.recovery.compositeScore),
                    const SizedBox(height: 8),
                    Text(
                      staleHighIntensityPlan
                          ? 'Plan unavailable in current safety mode'
                          : plan?.sessionName ?? trace.restReason ?? 'Rest day',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    if (plan != null) Text(planTimingLabel(plan)),
                    const SizedBox(height: 12),
                    if (staleHighIntensityPlan)
                      Text(
                        'This recommendation cannot be started under the current travel/recovery settings. Regenerate it or redo today\'s check-in.',
                        style: Theme.of(context).textTheme.bodyMedium,
                      )
                    else
                      FutureBuilder<String>(
                        future: _explanation,
                        builder: (context, snap) {
                          if (!snap.hasData) {
                            return const SizedBox(
                              height: 16,
                              width: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            );
                          }
                          return Text(snap.data!, style: Theme.of(context).textTheme.bodyMedium);
                        },
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (controller.settings.travelMode) ...[
              Card(
                color: Theme.of(context).colorScheme.tertiaryContainer,
                child: ListTile(
                  leading: const Icon(Icons.luggage),
                  title: const Text('Travel mode active'),
                  subtitle: const Text(
                    'No-equipment variants are in use. Load progression is paused; completed work still counts.',
                  ),
                  trailing: loggingStarted
                      ? null
                      : TextButton(
                          onPressed: _changingTravelMode ? null : _toggleTravelMode,
                          child: const Text('End'),
                        ),
                ),
              ),
              const SizedBox(height: 8),
            ],
            if (plan != null)
              ..._playOrder(plan.exercises).map((e) => Card(
                    child: ListTile(
                      leading: e.supersetGroup != null
                          ? CircleAvatar(
                              radius: 14,
                              child: Text(String.fromCharCode(65 + e.supersetGroup!),
                                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                            )
                          : (e.isWarmup ? const Icon(Icons.local_fire_department_outlined) : null),
                      title: Row(
                        children: [
                          Expanded(
                            child: Text(
                              e.name,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${e.isWarmup ? 'Warm-up · ${e.targetLabel}' : '${e.sets} x ${e.targetLabel}'}'
                            '${e.loadDisplay != null ? ' @ ${e.loadDisplay}' : ''}'
                            '${e.substitutedFrom != null ? ' (sub for ${e.substitutedFrom})' : ''}'
                            '${e.supersetGroup != null ? ' · superset ${String.fromCharCode(65 + e.supersetGroup!)}' : ''}',
                          ),
                          if (e.instruction != null)
                            Text(e.instruction!, style: Theme.of(context).textTheme.bodySmall),
                          if (!e.isWarmup &&
                              e.progressionFraction != null) ...[
                            const SizedBox(height: 10),
                            ProgressionPanel(exercise: e),
                          ],
                        ],
                      ),
                      trailing: e.isWarmup ? null : Text('RIR ${_rirLabel(e.rirTarget.name)}'),
                    ),
                  )),
            if (primaryCardioPrescription != null)
              CardioPrescriptionCard(
                prescription: primaryCardioPrescription,
              ),
            if (finisherHint != null)
              Card(
                color: Theme.of(context).colorScheme.tertiaryContainer,
                child: ListTile(
                  leading: const Icon(Icons.bolt),
                  title: Text(finisherHint),
                ),
              ),
            const SizedBox(height: 24),
            if (done)
              Card(
                color: Theme.of(context).colorScheme.secondaryContainer,
                child: const ListTile(
                  leading: Icon(Icons.check_circle),
                  title: Text('Session complete'),
                  subtitle: Text('Nice work — see it on the History tab.'),
                ),
              )
            else if (loggingStarted)
              Card(
                color: Theme.of(context).colorScheme.secondaryContainer,
                child: const ListTile(
                  leading: Icon(Icons.check_circle_outline),
                  title: Text('Workout attempt saved'),
                  subtitle: Text(
                    'The primary plan is locked for today. Any eligible later-day REHIT appears separately below.',
                  ),
                ),
              )
            else if (plan != null && sessionTemplates[plan.sessionId]?.isCardioOnly == true)
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  icon: const Icon(Icons.directions_bike),
                  onPressed: _loggingCardio
                      ? null
                      : () => _logCardio(
                            plan.sessionId,
                            plan: plan,
                          ),
                  label: const Text('Log cardio attempt'),
                ),
              )
            else if (plan != null && plan.exercises.isNotEmpty)
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.of(context)
                      .push(MaterialPageRoute(builder: (_) => LoggerScreen(plan: plan))),
                  child: const Text('Start session'),
                ),
              )
            else if (plan != null)
              Card(
                color: Theme.of(context).colorScheme.errorContainer,
                child: const ListTile(
                  leading: Icon(Icons.info_outline),
                  title: Text('No exercises available for this plan'),
                  subtitle: Text('Choose another option below or redo your check-in.'),
                ),
              ),

            // The controller's shared readiness/safety result also drives the
            // notification scheduler. Unsafe days stay silent here.
            if (secondRehitPrescription != null) ...[
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Optional CAROL REHIT Intense',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      ...cardioPrescriptionSummaryLines(secondRehitPrescription)
                          .map((line) => Text(line)),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerRight,
                        child: FilledButton.tonalIcon(
                          icon: const Icon(Icons.bolt),
                          onPressed: _loggingCardio
                              ? null
                              : () => _logCardio(SessionTypeId.s7),
                          label: const Text('Log CAROL preset'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            if (restDayRehitPrescription != null) ...[
              const SizedBox(height: 12),
              Card(
                key: const Key('today-rest-day-rehit'),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Nothing logged today',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        restDayRehitSlotLine(restDayRehit),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 6),
                      ...cardioPrescriptionSummaryLines(restDayRehitPrescription)
                          .map((line) => Text(line)),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerRight,
                        child: FilledButton.tonalIcon(
                          icon: const Icon(Icons.bolt),
                          onPressed: _loggingCardio
                              ? null
                              : () => _logCardio(SessionTypeId.s7),
                          label: const Text('Log CAROL preset'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            if (!done && !loggingStarted && alternatives.isNotEmpty) ...[
              const SizedBox(height: 24),
              Text('Other options today', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 2),
              Text(
                "Switch if you'd rather do one of these - today's readiness, time, and pain "
                'adjustments still apply to whichever you pick.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              ...alternatives.map((c) {
                final effectiveId = _effectiveAlternativeId(trace, c.sessionId);
                String? modulationLabel;
                if (effectiveId == SessionTypeId.s6 && effectiveId != c.sessionId) {
                  modulationLabel =
                      '~${trace.checkin.timeMinutes} min · Substitutes high-intensity cardio due to today\'s recovery/safety gate';
                } else if (effectiveId == SessionTypeId.s7 && effectiveId != c.sessionId) {
                  modulationLabel = trace.checkin.timeMinutes < 35
                      ? 'CAROL preset (08:40) · '
                          'Substitutes queued 4×4 due to time'
                      : 'CAROL preset (08:40) · '
                          'Substitutes 4×4 due to YELLOW readiness';
                }
                final def = sessionTypes[effectiveId]!;
                final isSwapping = _swapping == c.sessionId;
                // A natively-60-min session in a 35-min slot runs 60->35
                // compressed (accessories dropped) - say so honestly.
                final tierLabel = modulationLabel ??
                    (c.tier == SessionTier.full && def.fullDurationMin >= 60
                        ? 'compressed to 35 min'
                        : candidateTimingLabel(
                            effectiveId,
                            effectiveId == SessionTypeId.s3 ||
                                    effectiveId == SessionTypeId.s7
                                ? candidateReason(c)
                                : '${c.tier.name} tier · ${candidateReason(c)}',
                          ));
                return Card(
                  child: ListTile(
                    title: Text(def.name),
                    subtitle: Text(tierLabel),
                    trailing: isSwapping
                        ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.swap_horiz),
                    onTap: _swapping != null ? null : () => _swapTo(c.sessionId),
                  ),
                );
              }),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _confirmResetToday(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Redo check-in?'),
        content: const Text(
          "This discards today's check-in and recommendation (readiness numbers, pain flags, "
          'the plan you\'re looking at) so you can enter it again from scratch. '
          "This is available only before a workout attempt has been logged today.",
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Redo check-in')),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    await context.read<AppController>().resetToday();
    if (!context.mounted) return;
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const CheckInScreen()));
  }

  String _rirLabel(String name) => switch (name) {
        'rir0' => '0',
        'rir1' => '1',
        'rir2' => '2',
        'rir4plus' => '4+',
        _ => '3+',
      };

  bool _sameDate(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}

/// §4.3's GREEN/YELLOW/RED bucket, made visible - not just a value buried
/// in the trace.
class _ReadinessBadge extends StatelessWidget {
  final ReadinessBucket bucket;
  final double score;

  const _ReadinessBadge({required this.bucket, required this.score});

  Color get _color => switch (bucket) {
        ReadinessBucket.green => Colors.green,
        ReadinessBucket.yellow => Colors.amber.shade800,
        ReadinessBucket.red => Colors.red,
      };

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: _color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: _color),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 10, height: 10, decoration: BoxDecoration(color: _color, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Text(
            '${bucket.name.toUpperCase()} · ${score.round()}',
            style: TextStyle(color: _color, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }
}
