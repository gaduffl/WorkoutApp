import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/hov_foot_warmup.dart';

/// Original demonstration links supplied with the HOV program. Videos remain
/// with their publisher; no patient document or video is bundled in the app.
class HovExerciseGuide extends StatelessWidget {
  final String trackKey;
  const HovExerciseGuide({super.key, required this.trackKey});

  static const _videos = {
    HovFootWarmup.bridge: '1NsYpy-KSAxsDl2ljGvixBSORMtLPX_8m',
    HovFootWarmup.roll: '1ZYYcM3KABQ3ZLBh9jY3gkQMj8_I3OZhP',
    HovFootWarmup.hinge: '18xNSEoudS1q30zygcCBP4ReuPIzwNDRV',
    HovFootWarmup.lifts: '1MIsWS1cb_szoK0MEuDfNRp-_QivwiIvY',
    HovFootWarmup.steps: '1Sda3SCSXhSXbB285xyEHu4IZOCQb7DNj',
  };

  @override
  Widget build(BuildContext context) {
    final id = _videos[trackKey];
    if (id == null) return const SizedBox.shrink();
    return TextButton.icon(
      icon: const Icon(Icons.play_circle_outline),
      label: const Text('HOV exercise video'),
      onPressed: () async {
        var opened = false;
        try {
          opened = await launchUrl(
            Uri.https('drive.google.com', '/file/d/$id/view'),
            mode: LaunchMode.externalApplication,
          );
        } catch (_) {
          // The written cue remains usable without a browser or connection.
        }
        if (!opened && context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Could not open the HOV video. Please try again later.',
              ),
            ),
          );
        }
      },
    );
  }
}
