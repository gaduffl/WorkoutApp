import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../ai/ai_explainer.dart';
import '../../engine/session_templates.dart';
import '../../models/decision_trace.dart';
import '../../models/pain.dart';
import '../../models/plan.dart';
import '../../models/session_type.dart';
import '../../state/app_controller.dart';
import 'checkin_screen.dart';
import 'logger_screen.dart';

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

  /// A short, honest reason a candidate ranked where it did - drawn from
  /// the same score terms the engine used (§5 Step 4), not invented.
  String _candidateReason(ScoredCandidate c) {
    final terms = c.scoreTerms;
    if (terms.containsKey('floorForceStrength') || terms.containsKey('floorForceIntensity')) {
      return 'Would catch up your weekly floor';
    }
    if (terms.containsKey('floorSoftBoost')) return 'Slightly behind on your weekly floor';
    if (terms.containsKey('legHeavyDemoted')) return 'Deprioritized - legs were worked yesterday';
    if (terms.containsKey('recencyBoost')) return "Covers a pattern you haven't trained in a while";
    if (terms.containsKey('weekendPriority')) return 'Prioritized for your weekend schedule';
    return 'Next up in your rotation';
  }

  SessionTypeId _effectiveAlternativeId(DecisionTrace trace, SessionTypeId sourceId) {
    if (trace.recovery.bucket == ReadinessBucket.red &&
        (sourceId == SessionTypeId.s3 || sourceId == SessionTypeId.s7)) {
      return SessionTypeId.s6;
    }
    if (sourceId == SessionTypeId.s3 &&
        (trace.checkin.timeMinutes < 35 || trace.recovery.bucket == ReadinessBucket.yellow)) {
      return SessionTypeId.s7;
    }
    return sourceId;
  }

  Future<void> _logCardio(
    SessionTypeId id,
    int minutes, {
    SessionPlan? plan,
  }) async {
    if (_loggingCardio) return;
    setState(() => _loggingCardio = true);
    final controller = context.read<AppController>();
    try {
      await controller.logCardioSession(id, durationMinutes: minutes, plan: plan);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${sessionTypes[id]!.name} logged ✓')));
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
    final plan = trace.plan;
    final done = controller.sessionDoneToday;
    final loggingStarted = controller.sessionLoggedToday;
    final noOpAlternativeIds = <SessionTypeId>{if (plan != null) plan.sessionId};
    final firedCodes = trace.firedRuleCodes.toSet();
    if (firedCodes.contains('S7_TIME_SUB') || firedCodes.contains('YELLOW_4X4_TO_REHIT')) {
      noOpAlternativeIds.add(SessionTypeId.s3);
    }
    if (firedCodes.contains('RED_SWAP_Z2')) {
      noOpAlternativeIds.addAll(const {SessionTypeId.s3, SessionTypeId.s7});
    }
    final sharpHipPain = trace.checkin.pain.any(
      (flag) => flag.region == BodyRegion.hip && flag.severity == PainSeverity.sharp,
    );
    final seenEffectiveAlternatives = <SessionTypeId>{};
    final alternatives = plan == null
        ? <ScoredCandidate>[]
        : trace.candidates
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
            onPressed: () => _confirmResetToday(context),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _ReadinessBadge(bucket: trace.recovery.bucket, score: trace.recovery.compositeScore),
                    const SizedBox(height: 8),
                    Text(
                      plan?.sessionName ?? trace.restReason ?? 'Rest day',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    if (plan != null) Text('${plan.tier.name} tier - ~${plan.estimatedDurationMin} min'),
                    const SizedBox(height: 12),
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
              ...plan.exercises.map((e) => Card(
                    child: ListTile(
                      leading: e.supersetGroup != null
                          ? CircleAvatar(
                              radius: 14,
                              child: Text(String.fromCharCode(65 + e.supersetGroup!),
                                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                            )
                          : (e.isWarmup ? const Icon(Icons.local_fire_department_outlined) : null),
                      title: Text(e.name),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${e.isWarmup ? 'warm-up' : '${e.sets} x ${e.repRange.$1}-${e.repRange.$2} reps'}'
                            '${e.loadDisplay != null ? ' @ ${e.loadDisplay}' : ''}'
                            '${e.substitutedFrom != null ? ' (sub for ${e.substitutedFrom})' : ''}'
                            '${e.supersetGroup != null ? ' · superset ${String.fromCharCode(65 + e.supersetGroup!)}' : ''}',
                          ),
                          if (e.instruction != null)
                            Text(e.instruction!, style: Theme.of(context).textTheme.bodySmall),
                        ],
                      ),
                      trailing: e.isWarmup ? null : Text('RIR ${_rirLabel(e.rirTarget.name)}'),
                    ),
                  )),
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
            else if (plan != null && sessionTemplates[plan.sessionId]?.isCardioOnly == true)
              // Cardio-only session (S3 4×4, S6 Zone 2, S7 REHIT): nothing to
              // log set-by-set, just mark it done.
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  icon: const Icon(Icons.directions_bike),
                  onPressed: _loggingCardio
                      ? null
                      : () => _logCardio(
                            plan.sessionId,
                            plan.estimatedDurationMin,
                            plan: plan,
                          ),
                  label: Text('Mark ${plan.sessionName} done'),
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

            // §2.1/§12 second-session REHIT offer: after a strength session
            // with no intensity in the trailing 48 h.
            if (controller.canOfferSecondRehit) ...[
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Add an 8-min REHIT?', style: Theme.of(context).textTheme.titleMedium),
                      const Text('Covers your weekly intensity floor — the bike runs the protocol.'),
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerRight,
                        child: FilledButton.tonalIcon(
                          icon: const Icon(Icons.bolt),
                          onPressed: _loggingCardio ? null : () => _logCardio(SessionTypeId.s7, 10),
                          label: const Text('Log REHIT'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            if (!done && alternatives.isNotEmpty) ...[
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
                      '~${trace.checkin.timeMinutes} min · Substitutes high-intensity cardio due to RED readiness';
                } else if (effectiveId == SessionTypeId.s7 && effectiveId != c.sessionId) {
                  modulationLabel = trace.checkin.timeMinutes < 35
                      ? '${sessionTypes[SessionTypeId.s7]!.fullDurationMin} min · '
                          'Substitutes queued 4×4 due to time'
                      : '${sessionTypes[SessionTypeId.s7]!.fullDurationMin} min · '
                          'Substitutes 4×4 due to YELLOW readiness';
                }
                final def = sessionTypes[effectiveId]!;
                final isSwapping = _swapping == c.sessionId;
                // A natively-60-min session in a 35-min slot runs 60->35
                // compressed (accessories dropped) - say so honestly.
                final tierLabel = modulationLabel ??
                    (c.tier == SessionTier.full && def.fullDurationMin >= 60
                        ? 'compressed to 35 min'
                        : '${c.tier.name} tier · ${_candidateReason(c)}');
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
          "If you haven't logged any sets yet today, nothing else is affected. "
          "If you've already logged part of a session, that workout data is kept either way - "
          'only the check-in itself is reset.',
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
