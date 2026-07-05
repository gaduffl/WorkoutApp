import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/floor_category.dart';
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
  late TextEditingController _ouraController;
  late TextEditingController _apiKeyController;

  @override
  void initState() {
    super.initState();
    _settings = context.read<AppController>().settings;
    _ageController = TextEditingController(text: _settings.age.toString());
    _hrMaxController = TextEditingController(text: _settings.hrMaxOverride?.toStringAsFixed(0) ?? '');
    _ouraController = TextEditingController(text: _settings.ouraToken ?? '');
    _apiKeyController = TextEditingController(text: _settings.anthropicApiKey ?? '');
  }

  @override
  void dispose() {
    _ageController.dispose();
    _hrMaxController.dispose();
    _ouraController.dispose();
    _apiKeyController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final newSettings = _settings.copyWith(
      age: int.tryParse(_ageController.text) ?? _settings.age,
      hrMaxOverride: double.tryParse(_hrMaxController.text),
      ouraToken: _ouraController.text.isEmpty ? null : _ouraController.text,
      anthropicApiKey: _apiKeyController.text.isEmpty ? null : _apiKeyController.text,
    );
    await context.read<AppController>().saveSettings(newSettings);
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Settings saved')));
  }

  @override
  Widget build(BuildContext context) {
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
            const Divider(height: 32),
            Text('Weekly floor', style: Theme.of(context).textTheme.titleMedium),
            ListTile(
              title: const Text('Strength sessions / week'),
              trailing: _stepper(
                _settings.weeklyFloor[FloorCategory.strength] ?? 2,
                (v) => setState(() => _settings = _settings.copyWith(
                    weeklyFloor: {..._settings.weeklyFloor, FloorCategory.strength: v})),
              ),
            ),
            ListTile(
              title: const Text('Intensity sessions / week'),
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
            Text('Integrations (optional)', style: Theme.of(context).textTheme.titleMedium),
            TextField(controller: _ouraController, decoration: const InputDecoration(labelText: 'Oura personal access token')),
            TextField(
              controller: _apiKeyController,
              decoration: const InputDecoration(labelText: 'Anthropic API key (for AI "why" text)'),
              obscureText: true,
            ),
            const SizedBox(height: 24),
            FilledButton(onPressed: _save, child: const Text('Save settings')),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () => context.read<AppController>().triggerManualDeload(),
              child: const Text("I'm feeling beat up - deload everything"),
            ),
          ],
        ),
      ),
    );
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
