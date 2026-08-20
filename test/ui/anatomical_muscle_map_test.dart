import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:morningcoach/models/training_targets.dart';
import 'package:morningcoach/ui/widgets/anatomical_muscle_map.dart';
import 'package:morningcoach/ui/widgets/muscle_map_paths.dart';
import 'package:morningcoach/ui/widgets/svg_path_parser.dart';

void main() {
  test('bundled front and back anatomy is detailed and fully parseable', () {
    expect(maleFrontMuscleMap.groups, hasLength(greaterThanOrEqualTo(20)));
    expect(maleBackMuscleMap.groups, hasLength(greaterThanOrEqualTo(15)));
    expect(
      maleFrontMuscleMap.groups.expand((group) => group.paths),
      hasLength(greaterThan(90)),
    );
    expect(
      maleBackMuscleMap.groups.expand((group) => group.paths),
      hasLength(greaterThan(60)),
    );

    for (final body in [maleFrontMuscleMap, maleBackMuscleMap]) {
      for (final data in body.groups.expand((group) => group.paths)) {
        final path = parseSvgPathData(data);
        expect(path.getBounds().isEmpty, isFalse, reason: data);
      }
    }
  });

  test('anatomical slugs reuse the nine-group ledger without lumbar guesses', () {
    expect(
      majorMuscleGroupForAnatomicalSlug('quadriceps'),
      MajorMuscleGroup.quads,
    );
    expect(
      majorMuscleGroupForAnatomicalSlug('upper-back'),
      MajorMuscleGroup.back,
    );
    expect(
      majorMuscleGroupForAnatomicalSlug('forearm'),
      MajorMuscleGroup.coreGrip,
    );
    expect(majorMuscleGroupForAnatomicalSlug('lower-back'), isNull);
    expect(majorMuscleGroupForAnatomicalSlug('calves'), isNull);
  });

  testWidgets('renders labeled anatomical front and back views', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: SizedBox(
          width: 360,
          height: 260,
          child: AnatomicalMuscleMap(
            values: {MajorMuscleGroup.chest: 1},
          ),
        ),
      ),
    );

    expect(find.text('Front'), findsOneWidget);
    expect(find.text('Back'), findsOneWidget);
    expect(
      find.byKey(const Key('anatomical-muscle-map-paint')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
