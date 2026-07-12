import 'package:flutter_test/flutter_test.dart';

import 'package:morningcoach/data/serializers.dart';
import 'package:morningcoach/models/floor_category.dart';
import 'package:morningcoach/models/plan.dart';
import 'package:morningcoach/models/session_log.dart';
import 'package:morningcoach/models/session_type.dart';

void main() {
  test('travel context round-trips on plans and session logs', () {
    const plan = SessionPlan(
      sessionId: SessionTypeId.s1,
      sessionName: 'Strength — Lower',
      tier: SessionTier.full,
      exercises: [],
      estimatedDurationMin: 35,
      travelMode: true,
    );
    expect(sessionPlanFromJson(sessionPlanToJson(plan)).travelMode, isTrue);

    final log = SessionLog(
      id: 'travel-session',
      templateId: SessionTypeId.s1,
      tier: SessionTier.full,
      date: DateTime(2026, 7, 12),
      setLogs: const [],
      plannedWorkSets: 0,
      completedWorkSets: 0,
      durationMinutes: 35,
      countsAs: const {FloorCategory.strength},
      travelMode: true,
    );
    expect(sessionLogFromJson(sessionLogToJson(log)).travelMode, isTrue);
  });

  test('older persisted data defaults travel context to false', () {
    final planJson = sessionPlanToJson(const SessionPlan(
      sessionId: SessionTypeId.s6,
      sessionName: 'Zone 2',
      tier: SessionTier.full,
      exercises: [],
      estimatedDurationMin: 35,
    ))..remove('travelMode');

    expect(sessionPlanFromJson(planJson).travelMode, isFalse);
  });
}
