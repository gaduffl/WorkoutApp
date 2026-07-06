import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/floor_category.dart';
import '../../models/oura_connection.dart';
import '../../models/user_settings.dart';
import '../../state/app_controller.dart';

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

  @override
  void initState() {
    super.initState();
    _settings = context.read<AppController>().settings;
    _ageController = TextEditingController(text: _settings.age.toString());
    _hrMaxController = TextEditingController(text: _settings.hrMaxOverride?.toStringAsFixed(0) ?? '');
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
    final controller = context.read<AppController>();
    final newSettings = controller.settings.copyWith(
      equipment: _settings.equipment,
      weeklyFloor: _settings.weeklyFloor,
      language: _settings.language,
      age: int.tryParse(_ageController.text) ?? _settings.age,
      hrMaxOverride: double.tryParse(_hrMaxController.text),
      anthropicApiKey: _apiKeyController.text.isEmpty ? null : _apiKeyController.text,
      aiExplanationsEnabled: _settings.aiExplanationsEnabled,
      travelMode: _settings.travelMode,
    );
    await controller.saveSettings(newSettings);
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Settings saved')));
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

  @override
  Widget build(BuildContext context) {
    final oura = context.watch<AppController>().settings.oura;
    final ouraError = context.watch<AppController>().ouraError;

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
              title: const Text('Travel mode (no equipment)'),
              subtitle: const Text('Ladders resolve to bodyweight variants; load progression pauses, '
                  'sessions still count toward queue and weekly floor (§12)'),
              value: _settings.travelMode,
              onChanged: (v) => setState(() {
                _settings = _settings.copyWith(travelMode: v);
              }),
            ),
            const Divider(height: 32),
            Text('Weekly floor', style: Theme.of(context).textTheme.titleMedium),
            Text(
              'Design spec default (§2.2): >= 2 strength, >= 1 intensity per rolling 7 days. '
              'Change these only if you deliberately want a different minimum.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            ListTile(
              title: const Text('Strength sessions / week'),
              subtitle: Text(
                (_settings.weeklyFloor[FloorCategory.strength] ?? 2) == 2 ? 'Spec default' : 'Spec default is 2',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              trailing: _stepper(
                _settings.weeklyFloor[FloorCategory.strength] ?? 2,
                (v) => setState(() => _settings = _settings.copyWith(
                    weeklyFloor: {..._settings.weeklyFloor, FloorCategory.strength: v})),
              ),
            ),
            ListTile(
              title: const Text('Intensity sessions / week'),
              subtitle: Text(
                (_settings.weeklyFloor[FloorCategory.intensity] ?? 1) == 1 ? 'Spec default' : 'Spec default is 1',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              trailing: _stepper(
                _settings.weeklyFloor[FloorCategory.intensity] ?? 1,
                (v) => setState(() => _settings = _settings.copyWith(
                    weeklyFloor: {..._settings.weeklyFloor, FloorCategory.intensity: v})),
              ),
            ),
            const Divider(height: 32),
            Text('Profile', style: Theme.of(context).textTheme.titleMedium),
            TextField(controller: _ageController, decoration: const InputDecoration(labelText: 'Age'), keyboardType: TextInputType.number),
            TextField(
              controller: _hrMaxController,
              decoration: const InputDecoration(labelText: 'HRmax override (blank = 208 - 0.7 x age)'),
              keyboardType: TextInputType.number,
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
              controller: _apiKeyController,
              decoration: const InputDecoration(labelText: 'Anthropic API key (for AI "why" text)'),
              obscureText: true,
            ),
            const SizedBox(height: 24),
            FilledButton(onPressed: _save, child: const Text('Save settings')),
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
          '(one small step back from where it was, so you ease back in rather than jumping '
          'straight to your old working weight).\n\n'
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

  Widget _stepper(int value, void Function(int) onChanged) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(onPressed: () => onChanged((value - 1).clamp(0, 7)), icon: const Icon(Icons.remove)),
        Text('$value'),
        IconButton(onPressed: () => onChanged((value + 1).clamp(0, 7)), icon: const Icon(Icons.add)),
      ],
    );
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
