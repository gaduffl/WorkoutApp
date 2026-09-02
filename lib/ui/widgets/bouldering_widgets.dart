import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/bouldering_log.dart';

class BoulderingEntryDraft {
  final DateTime date;
  final int durationMinutes;
  final BoulderingEffort effort;

  const BoulderingEntryDraft({
    required this.date,
    required this.durationMinutes,
    required this.effort,
  });
}

Future<BoulderingEntryDraft?> showBoulderingEntryDialog(
  BuildContext context, {
  required DateTime today,
}) =>
    showDialog<BoulderingEntryDraft>(
      context: context,
      builder: (_) => _BoulderingEntryDialog(today: today),
    );

class _BoulderingEntryDialog extends StatefulWidget {
  final DateTime today;

  const _BoulderingEntryDialog({required this.today});

  @override
  State<_BoulderingEntryDialog> createState() =>
      _BoulderingEntryDialogState();
}

class _BoulderingEntryDialogState extends State<_BoulderingEntryDialog> {
  final _duration = TextEditingController();
  late DateTime _date;
  BoulderingEffort _effort = BoulderingEffort.moderate;
  String? _error;

  @override
  void initState() {
    super.initState();
    _date = DateTime(
      widget.today.year,
      widget.today.month,
      widget.today.day,
    );
  }

  @override
  void dispose() {
    _duration.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final yesterday = _dateOnly(
      widget.today.subtract(const Duration(days: 1)),
    );
    return AlertDialog(
      title: const Text('Log bouldering'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('When?'),
            const SizedBox(height: 6),
            SegmentedButton<DateTime>(
              segments: [
                ButtonSegment(
                  value: _dateOnly(widget.today),
                  label: const Text('Today'),
                ),
                ButtonSegment(
                  value: yesterday,
                  label: const Text('Yesterday'),
                ),
              ],
              selected: {_date},
              onSelectionChanged: (value) => setState(() {
                _date = value.single;
              }),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _duration,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                labelText: 'Duration (min)',
                helperText: 'Total time at the bouldering gym',
              ),
            ),
            const SizedBox(height: 16),
            const Text('Overall perceived effort'),
            const SizedBox(height: 6),
            SegmentedButton<BoulderingEffort>(
              segments: const [
                ButtonSegment(
                  value: BoulderingEffort.easy,
                  label: Text('Easy'),
                ),
                ButtonSegment(
                  value: BoulderingEffort.moderate,
                  label: Text('Moderate'),
                ),
                ButtonSegment(
                  value: BoulderingEffort.hard,
                  label: Text('Hard'),
                ),
              ],
              selected: {_effort},
              onSelectionChanged: (value) => setState(() {
                _effort = value.single;
              }),
            ),
            const SizedBox(height: 10),
            Text(
              'Used as an estimated pull/grip stimulus. It does not complete '
              'a MorningCoach workout or advance exercise progression.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _save,
          child: const Text('Save bouldering'),
        ),
      ],
    );
  }

  void _save() {
    final duration = int.tryParse(_duration.text.trim());
    if (duration == null || duration <= 0 || duration > 24 * 60) {
      setState(() {
        _error = 'Enter a duration between 1 minute and 24 hours.';
      });
      return;
    }
    Navigator.pop(
      context,
      BoulderingEntryDraft(
        date: _date,
        durationMinutes: duration,
        effort: _effort,
      ),
    );
  }

  DateTime _dateOnly(DateTime value) =>
      DateTime(value.year, value.month, value.day);
}
