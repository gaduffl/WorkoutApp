import 'package:flutter_test/flutter_test.dart';
import 'package:morningcoach/models/ladders.dart';
import 'package:morningcoach/models/movement_pattern.dart';
import 'package:morningcoach/ui/widgets/exercise_visual.dart';

void main() {
  test('exercise demos use explicit ExerciseDB media IDs', () {
    expect(exerciseDemoFor('pullUp')?.exerciseDbId, 'lBDjFxJ');
    expect(
      exerciseDemoFor('backExtensionDynamic')?.url,
      'https://static.exercisedb.dev/media/zhMwOwE.gif',
    );
    expect(exerciseDemoFor('unknown-import'), isNull);
  });

  test('approximate equipment variants do not inherit a demo', () {
    final squat = ladders[MovementPattern.squat]!;
    final pull = ladders[MovementPattern.pullVertical]!;
    final knee = ladders[MovementPattern.kneeHealth]!;

    expect(
      squat.steps.singleWhere((step) => step.name == 'ATG split squat').visualId,
      isNull,
    );
    expect(
      pull.steps.singleWhere((step) => step.name == 'Assisted pull-up').visualId,
      isNull,
    );
    expect(
      knee.steps.singleWhere((step) => step.name == 'Tibialis raise').visualId,
      isNull,
    );
    expect(
      travelNamedSteps['sub:coreGrip:db_curl']!.visualId,
      isNull,
    );
  });

  test('exact travel variants have their own demos', () {
    expect(
      travelSteps[MovementPattern.squat]!.visualId,
      'bodyweightSplitSquat',
    );
    expect(
      travelNamedSteps['sub:pushVertical:dip']!.visualId,
      'benchDip',
    );
  });
}
