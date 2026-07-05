import '../models/floor_category.dart';
import '../models/session_log.dart';

enum FloorPressureLevel { none, soft, hard }

class FloorPressureResult {
  final FloorPressureLevel level;
  final int deficit;

  const FloorPressureResult(this.level, this.deficit);
}

/// §5 Step 3: pure count-based weekly-floor pressure, no future-slot
/// estimation - every term is a count over logged history.
class FloorEngine {
  const FloorEngine();

  /// [logs] should already be filtered to completed (>=50%, §8) sessions;
  /// this method further restricts to the trailing [today-6, today-1] window.
  FloorPressureResult pressureFor({
    required FloorCategory category,
    required List<SessionLog> logs,
    required int requirement,
    required DateTime today,
  }) {
    final windowStart = today.subtract(const Duration(days: 6));
    final windowEnd = today.subtract(const Duration(days: 1));
    final categoryLogs = logs
        .where((l) =>
            l.countsAs.contains(category) &&
            l.countsTowardQueueAndFloor &&
            !l.date.isBefore(windowStart) &&
            !l.date.isAfter(windowEnd))
        .toList()
      ..sort((a, b) => a.date.compareTo(b.date));

    final deficit = requirement - categoryLogs.length;
    if (deficit <= 0) return FloorPressureResult(FloorPressureLevel.none, deficit);
    if (deficit >= 2) return FloorPressureResult(FloorPressureLevel.hard, deficit);

    // deficit == 1: aging-out horizon.
    if (categoryLogs.isEmpty) {
      return FloorPressureResult(FloorPressureLevel.hard, deficit);
    }
    final oldest = categoryLogs.first;
    final dropoutDate = oldest.date.add(const Duration(days: 7));
    final daysUntilDropout = dropoutDate.difference(today).inDays;
    return FloorPressureResult(
      daysUntilDropout <= 2 ? FloorPressureLevel.hard : FloorPressureLevel.soft,
      deficit,
    );
  }
}
