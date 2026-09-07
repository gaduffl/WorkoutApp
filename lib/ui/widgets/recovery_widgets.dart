import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../engine/recovery_program_engine.dart';
import '../../models/recovery_program.dart';
import '../../models/pain.dart';
import '../../state/app_controller.dart';

class RecoveryControls extends StatelessWidget {
  final bool showManage;
  const RecoveryControls({super.key, this.showManage = true});
  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    final program = controller.lowerBackRecovery.program;
    return Card(child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Lower-back recovery', style: Theme.of(context).textTheme.titleMedium),
        Text(program.phaseLabel),
        const SizedBox(height: 8),
        Text(program.reviewRequired
            ? 'Training paused: leg symptoms were reported, including resolved symptoms. Arrange a clinical assessment.'
            : 'Choose tolerated exercises. No automatic load or phase increases; no walking workouts or catch-up volume.'),
        if (program.latest?.urgent == true)
          const Text('New weakness, saddle numbness or bladder/bowel changes: seek urgent medical assessment.'),
        if (controller.stationaryBikePaused)
          const Text('Stationary cycling and cardio catch-up prompts are paused.'),
        if (program.pendingSession != null)
          const Text('Feedback is due later today and the following morning. Missing feedback holds progression.'),
        const SizedBox(height: 8),
        FilledButton.icon(
          key: const Key('recovery-symptom-check'), icon: const Icon(Icons.fact_check_outlined),
          label: const Text('Back symptom check'),
          onPressed: () => showDialog<void>(context: context,
            builder: (_) => _SymptomDialog(controller: controller)),
        ),
        OutlinedButton(
          key: const Key('recovery-new-flare'), child: const Text('New flare-up'),
          onPressed: () async {
            final confirmed = await showDialog<bool>(context: context, builder: (dialogContext) => AlertDialog(
              title: const Text('Pause progression after a flare-up?'),
              content: const Text('Return to the flare-up phase, pause stationary cycling and reset progression. Use the symptom check to record any leg symptoms and provoking exercises.'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
                FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Record flare-up')),
              ],
            ));
            if (confirmed == true) await controller.reportBackFlare();
          },
        ),
        if (showManage) TextButton(
          key: const Key('recovery-manage'), child: const Text('Exercises and progression'),
          onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const RecoveryProgramScreen())),
        ),
      ]),
    ));
  }
}

class _SymptomDialog extends StatefulWidget {
  final AppController controller;
  const _SymptomDialog({required this.controller});
  @override
  State<_SymptomDialog> createState() => _SymptomDialogState();
}
class _SymptomDialogState extends State<_SymptomDialog> {
  late final TextEditingController sitting;
  double pain = 0;
  RecoveryFunction function = RecoveryFunction.unchanged;
  final symptoms = <PainTag>{};
  final provoking = <RecoveryExercise>{};
  bool delayed = false, morning = false, saving = false;
  String? error;
  @override
  void initState() {
    super.initState();
    final last = widget.controller.lowerBackRecovery.program.latest;
    pain = (last?.pain ?? 0).toDouble();
    sitting = TextEditingController(text: last?.sittingMinutes.toString() ?? '');
  }
  @override
  void dispose() { sitting.dispose(); super.dispose(); }
  Future<void> save() async {
    final minutes = int.tryParse(sitting.text);
    if (minutes == null || minutes < 0 || minutes > 1440) {
      setState(() => error = 'Enter sitting tolerance from 0 to 1440 minutes.');
      return;
    }
    setState(() { saving = true; error = null; });
    try {
      await widget.controller.recordRecoveryObservation(RecoveryObservation(
        date: DateTime.now(), pain: pain.round(), sittingMinutes: minutes,
        function: function, symptoms: symptoms,
        delayedWorse: delayed, nextMorningWorse: morning, provoking: provoking,
      ));
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() { error = '$e'; saving = false; });
    }
  }
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Back symptom check'),
    content: SizedBox(width: 440, child: SingleChildScrollView(child: Column(
      mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Report symptoms since your previous check, even if they went away. Do not bend or lift to test your back.'),
        Text('Back pain now: ${pain.round()}/10'),
        Slider(value: pain, min: 0, max: 10, divisions: 10, onChanged: (v) => setState(() => pain = v)),
        TextField(controller: sitting, keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Comfortable sitting (minutes)', helperText: 'Usual time before discomfort; no deliberate test')),
        DropdownButtonFormField<RecoveryFunction>(
          value: function, decoration: const InputDecoration(labelText: 'Walking and everyday movement'),
          items: RecoveryFunction.values.map((v) => DropdownMenuItem(value: v, child: Text(v.name))).toList(),
          onChanged: (v) => setState(() => function = v!),
        ),
        CheckboxListTile(contentPadding: EdgeInsets.zero, title: const Text('Worse in the hours after exercise'), value: delayed,
          onChanged: (v) => setState(() => delayed = v!)),
        CheckboxListTile(contentPadding: EdgeInsets.zero, title: const Text('Worse the following morning'), value: morning,
          onChanged: (v) => setState(() => morning = v!)),
        const Text('Leg / neurological symptoms since last check'),
        for (final tag in PainTag.values)
          CheckboxListTile(contentPadding: EdgeInsets.zero,
            title: Text(switch (tag) {
              PainTag.radiating => 'Pain spreading into the leg',
              PainTag.numbness => 'Leg numbness', PainTag.tingling => 'Leg tingling (including resolved)',
              PainTag.weakness => 'New or worsening weakness',
              PainTag.saddleNumbness => 'Numbness around genitals / bottom',
              PainTag.bladderBowelChange => 'New bladder / bowel changes',
            }), value: symptoms.contains(tag),
            onChanged: (v) => setState(() { v! ? symptoms.add(tag) : symptoms.remove(tag); })),
        if (symptoms.any(const {PainTag.weakness, PainTag.saddleNumbness, PainTag.bladderBowelChange}.contains))
          const Text('Seek urgent medical assessment now. Do not continue training.'),
        if (delayed || morning || function == RecoveryFunction.worse) ...[
          const Text('Which movements provoked symptoms? Leave blank if uncertain; the last recovery exercises will be paused.'),
          for (final exercise in widget.controller.lowerBackRecovery.program.selected)
            CheckboxListTile(contentPadding: EdgeInsets.zero,
              title: Text(exercise.label), value: provoking.contains(exercise),
              onChanged: (v) => setState(() { v! ? provoking.add(exercise) : provoking.remove(exercise); })),
        ],
        if (error != null) Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
      ],
    ))),
    actions: [
      TextButton(onPressed: saving ? null : () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(onPressed: saving ? null : save, child: const Text('Save symptoms')),
    ],
  );
}

class RecoveryProgramScreen extends StatefulWidget {
  const RecoveryProgramScreen({super.key});
  @override
  State<RecoveryProgramScreen> createState() => _RecoveryProgramScreenState();
}
class _RecoveryProgramScreenState extends State<RecoveryProgramScreen> {
  bool busy = false;
  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    setState(() => busy = true);
    try { await action(); }
    catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally { if (mounted) setState(() => busy = false); }
  }
  Future<bool> confirm(String title, String body) async => await showDialog<bool>(
    context: context, builder: (c) => AlertDialog(title: Text(title), content: Text(body), actions: [
      TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
      FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Confirm')),
    ]),
  ) ?? false;

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    final program = controller.lowerBackRecovery.program;
    const engine = RecoveryProgramEngine();
    final ready = engine.canAdvance(program, controller.today());
    return Scaffold(appBar: AppBar(title: const Text('Recovery exercises and progression')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text(program.phaseLabel, style: Theme.of(context).textTheme.titleLarge),
        const Text('These are conservative training rules, not a diagnosis or evidence that tissue has healed. No fixed recovery deadline.'),
        Text('${program.toleratedExposures} complete tolerated exposures since the last change. '
            'An increase needs at least two, next-morning feedback and improving everyday function.'),
        const RecoveryControls(showManage: false),
        if (program.assessedAt == null || program.reviewRequired)
          OutlinedButton(onPressed: busy ? null : () => run(() async {
            if (program.latest?.symptoms.isNotEmpty != false || !program.checkedToday(controller.today())) {
              throw StateError('First record a current symptom check. Current neurological symptoms require medical advice.');
            }
            if (await confirm('Record a clinical assessment?',
                'Confirm that a qualified clinician has assessed the new symptoms and discussed appropriate exercise with you. This records your report, not a medical clearance issued by the app.')) {
              await controller.updateRecoveryProgram(engine.recordAssessment(program, DateTime.now()));
            }
          }), child: const Text('Record clinical assessment')),
        const SizedBox(height: 12),
        const Text('Select exercises you tolerate, including setup and getting on/off equipment. Only abdominal activation is available during the flare-up phase. Paused movements require an explicit re-trial.'),
        for (final exercise in RecoveryExercise.values) ...[
          CheckboxListTile(
            title: Text(exercise.label), value: program.selected.contains(exercise),
            subtitle: Text(program.pausedExercises.contains(exercise) ? 'Paused after symptoms' :
              exercise.needsAssessment && program.assessedAt == null ? 'Assessment required before prescription' :
              program.phase == RecoveryPhase.flareUp && exercise != RecoveryExercise.abdominalActivation ? 'Available in a later phase' :
              RecoveryProgramEngine.instructionFor(exercise)),
            onChanged: busy || exercise == RecoveryExercise.deadlift && controller.settings.deadliftAlternative
                ? null : (value) => run(() async {
              await controller.updateRecoveryProgram(engine.select(program, exercise, value!));
            })),
          if (program.selected.contains(exercise))
            Row(children: [
              Expanded(child: Text('${program.dose(exercise).reps} ${exercise.timed ? 'seconds' : 'reps'}'
                '${exercise.loaded ? ' · ${program.dose(exercise).load} lb' : ''}'
                '${exercise == RecoveryExercise.deadlift ? ' · ${program.dose(exercise).rangePercent}% range' : ''}')),
              TextButton(onPressed: busy ? null : () => _editDose(controller, exercise), child: const Text('Adjust')),
              if (program.pausedExercises.contains(exercise))
                TextButton(onPressed: busy || program.trainingBlocked ? null : () => run(() async {
                  if (await confirm('Re-trial ${exercise.label}?', 'Only retry after symptoms have settled and the movement is appropriate. The dose resets to its small starting dose; stop if symptoms return.')) {
                    await controller.updateRecoveryProgram(engine.retrial(program, exercise, controller.today()));
                  }
                }), child: const Text('Re-trial')),
            ]),
        ],
        const SizedBox(height: 12),
        if (program.phase != RecoveryPhase.returnToTraining)
          FilledButton(onPressed: busy || !ready ? null : () => run(() async {
            if (await confirm('Move to the next phase?', 'This does not establish healing or increase exercise loads. Only individually selected, eligible exercises can be prescribed.')) {
              await controller.updateRecoveryProgram(engine.advance(program, controller.today()));
            }
          }), child: const Text('Review next phase')),
        if (program.phase == RecoveryPhase.returnToTraining)
          FilledButton(onPressed: busy || !ready ? null : () => run(() async {
            if (await confirm('End recovery restrictions?', 'Normal strength selections may return. Deadlift alternatives and the separate cycling pause remain enabled if selected. This is your explicit return decision, not a healing certificate.')) {
              await controller.deactivateLowerBackRecovery();
              if (context.mounted) Navigator.pop(context);
            }
          }), child: const Text('End recovery mode')),
      ]),
    );
  }

  Future<void> _editDose(AppController controller, RecoveryExercise exercise) async {
    final program = controller.lowerBackRecovery.program;
    final old = program.dose(exercise);
    final reps = TextEditingController(text: '${old.reps}');
    final load = TextEditingController(text: '${old.load}');
    final range = TextEditingController(text: '${old.rangePercent}');
    final accepted = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
      title: Text('Adjust ${exercise.label}'),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('Change only one variable. Increases require complete tolerated exposures and improving function. Loads are total lb; choose a real, manageable setup, never a percentage of your old deadlift.'),
        TextField(controller: reps, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: exercise.timed ? 'Seconds (3–12)' : 'Reps (3–12)')),
        if (exercise.loaded) TextField(controller: load, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Total load (lb)')),
        if (exercise == RecoveryExercise.deadlift) TextField(controller: range, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Comfortable range % (10–100)')),
      ])),
      actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Apply'))],
    ));
    final r = int.tryParse(reps.text), p = int.tryParse(range.text);
    final w = double.tryParse(load.text);
    // Dialog fields are detached before their controllers are disposed.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    reps.dispose(); load.dispose(); range.dispose();
    if (accepted != true || !mounted) return;
    await run(() async {
      if (r == null || p == null || w == null) throw ArgumentError('Invalid dose.');
      await controller.updateRecoveryProgram(const RecoveryProgramEngine().adjustDose(
        program, exercise, RecoveryDose(reps: r, load: w, rangePercent: p), controller.today(), equipment: controller.settings.equipment,
      ));
    });
  }
}
