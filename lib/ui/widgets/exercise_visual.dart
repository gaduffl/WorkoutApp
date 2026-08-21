import 'package:flutter/material.dart';

/// A movement demo served by ExerciseDB V1's public media CDN.
///
/// MorningCoach deliberately keeps the media out of its repository and APK.
/// The explicit ID mapping prevents a similarly named substitution from
/// inheriting a demonstration for different equipment or a different motion.
class ExerciseDemo {
  final String exerciseDbId;
  final String sourceExerciseName;
  final String cue;

  const ExerciseDemo({
    required this.exerciseDbId,
    required this.sourceExerciseName,
    this.cue = 'Animated movement demo',
  });

  String get url => 'https://static.exercisedb.dev/media/$exerciseDbId.gif';
}

const Map<String, ExerciseDemo> exerciseDemos = {
  // Safe aliases keep already-persisted plans useful after the vector-to-media
  // migration. Ambiguous legacy IDs (for example dip/curl/splitSquat) are not
  // aliased because they were shared by exercises with different equipment.
  'gobletSquat': ExerciseDemo(
    exerciseDbId: 'yn8yg1r',
    sourceExerciseName: 'Dumbbell goblet squat',
  ),
  'dumbbellGobletSquat': ExerciseDemo(
    exerciseDbId: 'yn8yg1r',
    sourceExerciseName: 'Dumbbell goblet squat',
  ),
  'bodyweightSplitSquat': ExerciseDemo(
    exerciseDbId: '9E25EOx',
    sourceExerciseName: 'Bodyweight split squat',
  ),
  'pushUp': ExerciseDemo(
    exerciseDbId: 'I4hDWkc',
    sourceExerciseName: 'Push-up',
  ),
  'seatedDumbbellShoulderPress': ExerciseDemo(
    exerciseDbId: 'znQUdHY',
    sourceExerciseName: 'Seated dumbbell shoulder press',
  ),
  'seatedPress': ExerciseDemo(
    exerciseDbId: 'znQUdHY',
    sourceExerciseName: 'Seated dumbbell shoulder press',
  ),
  'pullUp': ExerciseDemo(
    exerciseDbId: 'lBDjFxJ',
    sourceExerciseName: 'Pull-up',
  ),
  'dumbbellInclineRow': ExerciseDemo(
    exerciseDbId: '7vG5o25',
    sourceExerciseName: 'Dumbbell incline row',
  ),
  'chestSupportedRow': ExerciseDemo(
    exerciseDbId: '7vG5o25',
    sourceExerciseName: 'Dumbbell incline row',
  ),
  'alternatingDumbbellCurl': ExerciseDemo(
    exerciseDbId: 'BU15nH4',
    sourceExerciseName: 'Alternating dumbbell biceps curl',
  ),
  'oneArmDumbbellLateralRaise': ExerciseDemo(
    exerciseDbId: 'n5cWCsI',
    sourceExerciseName: 'One-arm dumbbell lateral raise',
  ),
  'parallelBarDip': ExerciseDemo(
    exerciseDbId: '9WTm7dq',
    sourceExerciseName: 'Parallel-bar chest dip',
  ),
  'benchDip': ExerciseDemo(
    exerciseDbId: 'RrLske5',
    sourceExerciseName: 'Bench dip with bent knees',
  ),
  'backExtensionHold': ExerciseDemo(
    exerciseDbId: 'zhMwOwE',
    sourceExerciseName: 'Hyperextension',
    cue: 'Hold the neutral top position shown',
  ),
  'backExtensionDynamic': ExerciseDemo(
    exerciseDbId: 'zhMwOwE',
    sourceExerciseName: 'Hyperextension',
  ),
};

ExerciseDemo? exerciseDemoFor(String visualId) => exerciseDemos[visualId];

class ExerciseVisualCard extends StatelessWidget {
  final String visualId;
  final String exerciseName;

  const ExerciseVisualCard({
    super.key,
    required this.visualId,
    required this.exerciseName,
  });

  @override
  Widget build(BuildContext context) {
    final demo = exerciseDemoFor(visualId);
    if (demo == null) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Animated movement demo for $exerciseName',
      image: true,
      child: Card(
        key: ValueKey('exercise-visual-$visualId'),
        clipBehavior: Clip.antiAlias,
        color: scheme.surfaceContainerLow,
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
          child: Column(
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(
                  maxHeight: 180,
                  maxWidth: 180,
                ),
                child: AspectRatio(
                  aspectRatio: 1,
                  child: Image.network(
                    demo.url,
                    key: ValueKey('exercise-demo-image-$visualId'),
                    fit: BoxFit.contain,
                    filterQuality: FilterQuality.medium,
                    loadingBuilder: (context, child, loadingProgress) {
                      if (loadingProgress == null) return child;
                      return Center(
                        child: CircularProgressIndicator(
                          color: scheme.primary,
                          strokeWidth: 2,
                          value: loadingProgress.expectedTotalBytes == null
                              ? null
                              : loadingProgress.cumulativeBytesLoaded /
                                  loadingProgress.expectedTotalBytes!,
                        ),
                      );
                    },
                    errorBuilder: (context, error, stackTrace) => Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.cloud_off_outlined, color: scheme.outline),
                          const SizedBox(height: 6),
                          Text(
                            'Demo unavailable offline',
                            style: Theme.of(context).textTheme.labelMedium,
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                demo.cue,
                style: Theme.of(context).textTheme.labelMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 2),
              Text(
                '${demo.sourceExerciseName} · ExerciseDB / AscendAPI · © Gym visual',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
