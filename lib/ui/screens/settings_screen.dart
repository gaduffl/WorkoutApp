import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../engine/schedule_fit_engine.dart';
import '../../models/ladders.dart';
import '../../models/movement_pattern.dart';
import '../../notifications/notification_service.dart';
import '../../models/oura_connection.dart';
import '../../models/user_settings.dart';
import '../../state/app_controller.dart';
import '../widgets/progression_help_dialog.dart';
import 'insights_screen.dart' show formatMinuteOfDay;

String _editableHrMax(double? value) {
  if (value == null) return '';
  if (!value.isFinite) return value.toString();
  return value == value.roundToDouble()
      ? value.toInt().toString()
      : value.toString();
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late UserSettings _settings;
  late TextEditingController _ageController;
  late TextEditingController _hrMaxController;
  late TextEditingController _ouraClientIdController;
  late TextEditingController _ouraClientSecretController;
  late TextEditingController _apiKeyController;
  bool _connecting = false;
  String? _clearingPainTrack;

  @override
  void initState() {
    super.initState();
    _settings = context.read<AppController>().settings;
    _ageController = TextEditingController(text: _settings.age.toString());
    _hrMaxController = TextEditingController(
      text: _editableHrMax(_settings.hrMaxOverride),
    );
    _ouraClientIdController = TextEditingController(text: _settings.oura.clientId ?? '');
    _ouraClientSecretController = TextEditingController(text: _settings.oura.clientSecret ?? '');
    _apiKeyController = TextEditingController(text: _settings.anthropicApiKey ?? '');
  }

  @override
  void dispose() {
    _ageController.dispose();
    _hrMaxController.dispose();
    _ouraClientIdController.dispose();
    _ouraClientSecretController.dispose();
    _apiKeyController.dispose();
    super.dispose();
  }

  /// Bases the save on the controller's *current* settings (not the local
  /// draft) so a background change - e.g. Oura tokens arriving from the
  /// OAuth redirect while this screen was open - never gets clobbered by
  /// an unrelated field edit here.
  Future<void> _save() async {
    final ageText = _ageController.text.trim();
    final age = int.tryParse(ageText);
    if (age == null || age < 1 || age > 120) {
      _showSaveValidationError(
        'Age must be a whole number from 1 to 120.',
      );
      return;
    }

    final hrMaxText = _hrMaxController.text.trim();
    final parsedHrMax = hrMaxText.isEmpty ? null : double.tryParse(hrMaxText);
    if (hrMaxText.isNotEmpty &&
        (parsedHrMax == null ||
            !parsedHrMax.isFinite ||
            parsedHrMax < 30 ||
            parsedHrMax > 260)) {
      _showSaveValidationError(
        'HRmax override must be a finite number from 30 to 260, or left blank.',
      );
      return;
    }

    final apiKeyText = _apiKeyController.text.trim();
    final controller = context.read<AppController>();
    final newSettings = controller.settings.copyWith(
      equipment: _settings.equipment,
      language: _settings.language,
      age: age,
      hrMaxOverride: parsedHrMax,
      clearHrMaxOverride: hrMaxText.isEmpty,
      anthropicApiKey: apiKeyText.isEmpty ? null : apiKeyText,
      clearAnthropicApiKey: apiKeyText.isEmpty,
      aiExplanationsEnabled: _settings.aiExplanationsEnabled,
      travelMode: _settings.travelMode,
      notificationsEnabled: _settings.notificationsEnabled,
      secondRehitNudgeEnabled: _settings.secondRehitNudgeEnabled,
      restDayRehitNudgeEnabled: _settings.restDayRehitNudgeEnabled,
      wakeWindow: _settings.wakeWindow,
    );
    await controller.saveSettings(newSettings);
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Settings saved')));
  }

  /// The reminder's time is learned from history rather than configured, so
  /// state what it would actually be instead of describing a rule.
  String _restDayNudgeSubtitle(BuildContext context) {
    const base =
        'On days with nothing logged yet, get one push nudge to fit a short '
        'CAROL REHIT in.';
    final habits =
        context.read<AppController>().scheduleHabitsAt(DateTime.now());
    final median = habits.medianStartMinuteOfDay;
    if (median == null ||
        habits.startSampleCount < ScheduleFitEngine.minOverallSamples) {
      return '$base The time is learned from when you normally train.';
    }
    return '$base Aimed near ${formatMinuteOfDay(median)}, from when you '
        'normally train.';
  }

  void _showSaveValidationError(String message) {
    final messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _connectOura() async {
    setState(() => _connecting = true);
    final controller = context.read<AppController>();
    final oura = controller.settings.oura.copyWith(
      clientId: _ouraClientIdController.text.trim(),
      clientSecret: _ouraClientSecretController.text.trim(),
    );
    await controller.saveSettings(controller.settings.copyWith(oura: oura));
    final launched = await controller.startOuraConnect();
    if (mounted) {
      setState(() => _connecting = false);
      if (!launched) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't open the browser to connect to Oura.")),
        );
      }
    }
  }

  bool _odBusy = false;

  Future<void> _connectOneDrive() async {
    setState(() => _odBusy = true);
    final controller = context.read<AppController>();
    final launched = await controller.startOneDriveConnect();
    if (!mounted) return;
    setState(() => _odBusy = false);
    if (!launched) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text("Couldn't open the browser to connect to OneDrive.")));
    }
  }

  Future<void> _backupNow() async {
    setState(() => _odBusy = true);
    final controller = context.read<AppController>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      await controller.backupToOneDrive();
      messenger.showSnackBar(const SnackBar(content: Text('Backed up to OneDrive ✓')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Backup failed: $e')));
    }
    if (mounted) setState(() => _odBusy = false);
  }

  Future<void> _restoreNow() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Restore from OneDrive?'),
        content: const Text(
          'This replaces ALL data on this device (sessions, progress, settings) with the '
          'latest OneDrive backup. Your current data on this device is overwritten.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Restore')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _odBusy = true);
    final controller = context.read<AppController>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      final ok = await controller.restoreFromOneDrive();
      messenger.showSnackBar(SnackBar(content: Text(ok ? 'Restored from OneDrive ✓' : 'No backup found yet.')));
      if (ok && mounted) setState(() => _settings = controller.settings);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Restore failed: $e')));
    }
    if (mounted) setState(() => _odBusy = false);
  }

  String _fmtTime(DateTime t) {
    final l = t.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final controller = context.watch<AppController>();
    final oura = controller.settings.oura;
    final ouraError = controller.ouraError;
    final od = controller.settings.oneDrive;
    final odError = controller.oneDriveError;
    final frozenTracks = controller.exerciseStates.values.where((state) => state.painFrozen).toList()
      ..sort((a, b) => a.pattern.displayName.compareTo(b.pattern.displayName));

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('Equipment', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            ..._settings.equipment.blocks.map(
              (b) => ListTile(
                title: Text('${b.label} PowerBlock'),
                subtitle: Text('Steps: ${b.perDumbbellSteps.map((s) => s.toStringAsFixed(0)).join(', ')} lb'),
              ),
            ),
            SwitchListTile(
              title: const Text('Uneven-pair mode'),
              subtitle: const Text('Allows different weight per hand (max 5 lb diff), swap between sets'),
              value: _settings.equipment.unevenPairModeEnabled,
              onChanged: (v) => setState(() {
                _settings = _settings.copyWith(equipment: _settings.equipment.copyWith(unevenPairModeEnabled: v));
              }),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.luggage_outlined),
              title: const Text('Travel mode (no equipment)'),
              subtitle: const Text('Uses bodyweight and self-resisted variants. Load progression pauses, '
                  'but completed work still contributes to your stimulus history.'),
              value: _settings.travelMode,
              onChanged: (v) => setState(() {
                _settings = _settings.copyWith(travelMode: v);
              }),
            ),
            const Divider(height: 32),
            Text('Notifications', style: Theme.of(context).textTheme.titleMedium),
            SwitchListTile(
              title: const Text('Morning check-in reminders'),
              subtitle: Text('"Ready to plan today?" at ${_settings.wakeWindow}, plus a nudge at '
                  '${_settings.checkInCutoffHour}:00 if no check-in happened yet'),
              value: _settings.notificationsEnabled,
              onChanged: (v) async {
                if (v) {
                  final messenger = ScaffoldMessenger.of(context);
                  final granted = await NotificationService.requestPermission();
                  if (!granted) {
                    messenger.showSnackBar(
                      const SnackBar(content: Text('Notification permission was denied - reminders stay off.')),
                    );
                    return;
                  }
                }
                setState(() => _settings = _settings.copyWith(notificationsEnabled: v));
              },
            ),
            ListTile(
              title: const Text('Wake window'),
              subtitle: Text(_settings.wakeWindow),
              trailing: const Icon(Icons.schedule),
              onTap: () async {
                final parts = _settings.wakeWindow.split(':');
                final picked = await showTimePicker(
                  context: context,
                  initialTime: TimeOfDay(
                    hour: int.tryParse(parts.first) ?? 7,
                    minute: parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0,
                  ),
                );
                if (picked != null) {
                  setState(() => _settings = _settings.copyWith(
                        wakeWindow:
                            '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}',
                      ));
                }
              },
            ),
            SwitchListTile(
              title: const Text('Second REHIT reminder'),
              subtitle: const Text(
                'On days where a short extra REHIT would add value, get a '
                'push nudge later in the day to fit one in.',
              ),
              value: _settings.secondRehitNudgeEnabled,
              onChanged: (v) async {
                if (v) {
                  final messenger = ScaffoldMessenger.of(context);
                  final granted = await NotificationService.requestPermission();
                  if (!granted) {
                    messenger.showSnackBar(
                      const SnackBar(content: Text('Notification permission was denied - the REHIT reminder stays off.')),
                    );
                    return;
                  }
                }
                setState(() => _settings = _settings.copyWith(secondRehitNudgeEnabled: v));
              },
            ),
            SwitchListTile(
              key: const Key('settings-rest-day-rehit-nudge'),
              title: const Text('Rest-day REHIT reminder'),
              subtitle: Text(_restDayNudgeSubtitle(context)),
              value: _settings.restDayRehitNudgeEnabled,
              onChanged: (v) async {
                if (v) {
                  final messenger = ScaffoldMessenger.of(context);
                  final granted = await NotificationService.requestPermission();
                  if (!granted) {
                    messenger.showSnackBar(
                      const SnackBar(content: Text('Notification permission was denied - the rest-day reminder stays off.')),
                    );
                    return;
                  }
                }
                setState(() => _settings = _settings.copyWith(restDayRehitNudgeEnabled: v));
              },
            ),
            if (frozenTracks.isNotEmpty) ...[
              const Divider(height: 32),
              Text('Pain progression freezes', style: Theme.of(context).textTheme.titleMedium),
              Text(
                'These tracks stay frozen while the pain protocol is active. Clear one only when the '
                'flag is no longer relevant; its load and progression state are preserved.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 4),
              ...frozenTracks.map((state) => ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(state.pattern.displayName),
                    subtitle: Text(
                      '${state.painSeverity?.name ?? 'Pain'}'
                      '${state.painRegion == null ? '' : ' · ${_humanize(state.painRegion!.name)}'}'
                      '${state.trackKey == state.pattern.name ? '' : '\n${state.trackKey}'}',
                    ),
                    trailing: TextButton(
                      onPressed: _clearingPainTrack == null
                          ? () => _confirmClearPainFreeze(context, state.trackKey, state.pattern.displayName)
                          : null,
                      child: Text(_clearingPainTrack == state.trackKey ? 'Clearing…' : 'Clear'),
                    ),
                  )),
            ],
            const Divider(height: 32),
            Text('Profile', style: Theme.of(context).textTheme.titleMedium),
            TextField(
              key: const Key('settings-age'),
              controller: _ageController,
              decoration: const InputDecoration(labelText: 'Age'),
              keyboardType: TextInputType.number,
            ),
            TextField(
              key: const Key('settings-hr-max'),
              controller: _hrMaxController,
              decoration: const InputDecoration(labelText: 'HRmax override (blank = 208 - 0.7 x age)'),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
            ),
            const Divider(height: 32),
            Text('Language', style: Theme.of(context).textTheme.titleMedium),
            SegmentedButton<AppLanguage>(
              segments: const [
                ButtonSegment(value: AppLanguage.en, label: Text('English')),
                ButtonSegment(value: AppLanguage.de, label: Text('Deutsch')),
              ],
              selected: {_settings.language},
              onSelectionChanged: (s) => setState(() => _settings = _settings.copyWith(language: s.first)),
            ),
            const Divider(height: 32),
            Text('Oura', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Oura retired personal access tokens in Dec 2025 - connecting now uses OAuth2. '
              'Register a free API Application at cloud.ouraring.com/oauth/applications with '
              'redirect URI "morningcoach://oauth-callback", then paste its Client ID/Secret below.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            _OuraStatusChip(oura: oura),
            if (ouraError != null) ...[
              const SizedBox(height: 4),
              Text(ouraError, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ],
            const SizedBox(height: 8),
            TextField(controller: _ouraClientIdController, decoration: const InputDecoration(labelText: 'Oura Client ID')),
            TextField(
              controller: _ouraClientSecretController,
              decoration: const InputDecoration(labelText: 'Oura Client Secret'),
              obscureText: true,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: _connecting ? null : _connectOura,
                    child: _connecting
                        ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : Text(oura.isConnected ? 'Reconnect Oura' : 'Connect Oura'),
                  ),
                ),
                if (oura.isConnected) ...[
                  const SizedBox(width: 8),
                  OutlinedButton(
                    onPressed: () => context.read<AppController>().disconnectOura(),
                    child: const Text('Disconnect'),
                  ),
                ],
              ],
            ),
            const Divider(height: 32),
            Text('Backup & sync (OneDrive)', style: Theme.of(context).textTheme.titleMedium),
            Text(
              'Backs up all your data to a private folder in your OneDrive so you can '
              'restore it on a new device. The app can only see its own folder.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(od.isConnected ? Icons.cloud_done : Icons.cloud_off,
                    color: od.isConnected ? Colors.green : Colors.grey),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(od.isConnected
                      ? 'Connected${od.account != null ? ' · ${od.account}' : ''}'
                      : 'Not connected'),
                ),
              ],
            ),
            if (od.lastBackupAt != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('Last backup: ${_fmtTime(od.lastBackupAt!)}',
                    style: Theme.of(context).textTheme.bodySmall),
              ),
            if (odError != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(odError, style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12)),
              ),
            const SizedBox(height: 8),
            if (!od.isConnected)
              FilledButton.icon(
                icon: _odBusy
                    ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.cloud),
                onPressed: _odBusy ? null : _connectOneDrive,
                label: const Text('Connect OneDrive'),
              )
            else ...[
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      icon: const Icon(Icons.backup),
                      onPressed: _odBusy ? null : _backupNow,
                      label: const Text('Back up now'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.restore),
                      onPressed: _odBusy ? null : _restoreNow,
                      label: const Text('Restore'),
                    ),
                  ),
                ],
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Auto-backup after each session'),
                value: od.autoBackup,
                onChanged: _odBusy ? null : (v) => context.read<AppController>().setOneDriveAutoBackup(v),
              ),
              TextButton(
                onPressed: _odBusy ? null : () => context.read<AppController>().disconnectOneDrive(),
                child: const Text('Disconnect OneDrive'),
              ),
            ],
            const Divider(height: 32),
            Text('Progression level', style: Theme.of(context).textTheme.titleMedium),
            Text(
              'Jump a movement straight to the difficulty you actually train at — '
              'e.g. skip past push-ups if you are already well beyond them. '
              'The next session starts there and ramps quickly if it feels easy.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            ..._progressionPatterns.map((p) {
              final idx = context.watch<AppController>().currentLadderIndex(p);
              final steps = ladders[p]!.steps;
              final stepName = steps[idx.clamp(0, steps.length - 1)].name;
              return ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(_patternLabel(p)),
                subtitle: Text('Step ${idx + 1}/${steps.length}: $stepName'),
                trailing: const Icon(Icons.tune),
                onTap: () => _editProgression(p),
              );
            }),
            const Divider(height: 32),
            Text('Reset', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: Icon(Icons.delete_forever, color: Theme.of(context).colorScheme.error),
              style: OutlinedButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
              onPressed: () => _confirmResetDay(context),
              label: const Text('Reset today'),
            ),
            const Divider(height: 32),
            Text('Help & Rules', style: Theme.of(context).textTheme.titleMedium),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.help_outline),
              title: const Text('Progression rules'),
              subtitle: const Text('How Reps/Seconds and RIR determine weight and stage progression'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => showProgressionRulesDialog(context),
            ),
            const Divider(height: 32),
            Text('AI layer (optional)', style: Theme.of(context).textTheme.titleMedium),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Use AI "why" text'),
              subtitle: Text(
                _settings.aiExplanationsEnabled
                    ? "Off uses the app's fixed, deterministic explanation text instead (§9.1) - "
                        'same rules, no API call.'
                    : "Using the fixed, deterministic explanation text - the engine's rules never change, "
                        'only how the reasoning is worded.',
              ),
              value: _settings.aiExplanationsEnabled,
              onChanged: (v) => setState(() => _settings = _settings.copyWith(aiExplanationsEnabled: v)),
            ),
            TextField(
              key: const Key('settings-anthropic-api-key'),
              controller: _apiKeyController,
              decoration: const InputDecoration(labelText: 'Anthropic API key (for AI "why" text)'),
              obscureText: true,
            ),
            const SizedBox(height: 24),
            FilledButton(
              key: const Key('settings-save'),
              onPressed: _save,
              child: const Text('Save settings'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () => _confirmManualDeload(context),
              child: const Text("I'm feeling beat up - deload everything"),
            ),
          ],
        ),
      ),
    );
  }

  static const _progressionPatterns = [
    MovementPattern.squat,
    MovementPattern.hinge,
    MovementPattern.pushHorizontal,
    MovementPattern.pushVertical,
    MovementPattern.pullVertical,
    MovementPattern.pullHorizontal,
  ];

  static String _formatLoad(double v) =>
      v % 1 == 0 ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

  String _patternLabel(MovementPattern p) => switch (p) {
        MovementPattern.squat => 'Squat',
        MovementPattern.hinge => 'Hinge',
        MovementPattern.pushHorizontal => 'Horizontal push',
        MovementPattern.pushVertical => 'Vertical push',
        MovementPattern.pullVertical => 'Vertical pull',
        MovementPattern.pullHorizontal => 'Horizontal pull',
        _ => p.name,
      };

  Future<void> _editProgression(MovementPattern pattern) async {
    final controller = context.read<AppController>();
    final steps = ladders[pattern]!.steps;
    var selected = controller.currentLadderIndex(pattern).clamp(0, steps.length - 1);
    final loadController = TextEditingController();

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final step = steps[selected];
          final loaded = step.dumbbells > 0 || step.backpackLoaded;
          final lastLoad = controller.lastManualLoad(pattern, selected);
          return AlertDialog(
            title: Text('${_patternLabel(pattern)} level'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DropdownButton<int>(
                  isExpanded: true,
                  value: selected,
                  items: [
                    for (var i = 0; i < steps.length; i++)
                      DropdownMenuItem(value: i, child: Text('${i + 1}. ${steps[i].name}')),
                  ],
                  onChanged: (v) => setLocal(() => selected = v ?? selected),
                ),
                const SizedBox(height: 8),
                if (loaded)
                  TextField(
                    controller: loadController,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: step.backpackLoaded ? 'Added weight (lb, blank = bodyweight)' : 'Starting total load (lb, blank = auto)',
                      helperText: lastLoad != null
                          ? 'You last entered ${_formatLoad(lastLoad)} lb for this level'
                          : null,
                    ),
                  )
                else
                  const Text('Bodyweight movement — no load to set.'),
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Set level')),
            ],
          );
        },
      ),
    );
    if (saved != true || !mounted) return;
    final load = double.tryParse(loadController.text.trim());
    await controller.setPatternProgression(pattern, selected, startLoad: load);
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('${_patternLabel(pattern)} set to step ${selected + 1}')));
    }
  }

  Future<void> _confirmResetDay(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Reset today?'),
        content: const Text(
          "This permanently deletes ONLY today's data: your check-in, recovery entry, the "
          'recommended plan, and any sessions you logged today. Progression and the session '
          'queue are rolled back to how they were at the start of today.\n\n'
          'No other day is touched — your full history stays intact. This cannot be undone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(dialogContext).colorScheme.error),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete today'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await context.read<AppController>().resetDay();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Today reset ✓')));
    }
  }

  Future<void> _confirmManualDeload(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Deload everything?'),
        content: const Text(
          'This puts every trained movement pattern into a scheduled deload (§6.3/§6.5): '
          'the next 2 sessions that touch each pattern run at 60% of your current load, '
          'half the work sets, and RIR >= 4 (leave a lot in the tank). '
          "It's shown in the app as a deload, not a setback.\n\n"
          'After those 2 sessions, each pattern automatically returns to normal progression '
          'from its saved exercise and load, backed off by exactly one available prescription '
          'step (a dumbbell increment, 5 lb of backpack load, or one tempo/pause/ROM or '
          'bodyweight/hold-ladder stage).\n\n'
          "Use this when you're feeling generally beat up and want a planned lighter block, "
          'not for a single sore muscle or joint - use the pain flag on the check-in for that instead.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Deload everything')),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await context.read<AppController>().triggerManualDeload();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('All patterns are now in a 2-session deload.')),
      );
    }
  }

  Future<void> _confirmClearPainFreeze(
    BuildContext context,
    String trackKey,
    String patternName,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Clear $patternName pain freeze?'),
        content: const Text(
          'Only clear this when the pain flag is no longer relevant and it is appropriate to resume. '
          'This removes the stored pain flag and re-entry bookkeeping. It does not change the current '
          'load, ladder step, regression history, or deload state.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Clear freeze')),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    setState(() => _clearingPainTrack = trackKey);
    try {
      await context.read<AppController>().clearPainFreeze(trackKey);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$patternName pain freeze cleared.')));
      }
    } finally {
      if (mounted) setState(() => _clearingPainTrack = null);
    }
  }

  String _humanize(String value) {
    final spaced = value.replaceAllMapped(RegExp(r'([a-z])([A-Z])'), (m) => '${m[1]} ${m[2]}');
    return '${spaced[0].toUpperCase()}${spaced.substring(1)}';
  }

}

class _OuraStatusChip extends StatelessWidget {
  final OuraConnection oura;

  const _OuraStatusChip({required this.oura});

  @override
  Widget build(BuildContext context) {
    final (label, color) = oura.isConnected
        ? ('Connected', Colors.green)
        : oura.isConfigured
            ? ('Not connected', Colors.orange)
            : ('Not configured', Colors.grey);
    return Chip(
      avatar: Icon(Icons.circle, size: 12, color: color),
      label: Text(label),
    );
  }
}
