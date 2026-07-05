import 'package:flutter_test/flutter_test.dart';
import 'package:morningcoach/engine/queue_engine.dart';
import 'package:morningcoach/models/session_type.dart';

void main() {
  const engine = QueueEngine();

  test('cycle distance is 0 for the pointer, ascending for the rest', () {
    const state = QueueState(pointer: SessionTypeId.s3, served: {});
    expect(engine.cycleDistance(SessionTypeId.s3, state), 0);
    expect(engine.cycleDistance(SessionTypeId.s4, state), 1);
    expect(engine.cycleDistance(SessionTypeId.s5, state), 2);
    expect(engine.cycleDistance(SessionTypeId.s1, state), 3);
    expect(engine.cycleDistance(SessionTypeId.s2, state), 4);
  });

  test('a non-pointer cycle type pulled forward is served without moving the pointer', () {
    const state = QueueState(pointer: SessionTypeId.s1, served: {});
    final next = engine.advance(state, SessionTypeId.s3);
    expect(next.pointer, SessionTypeId.s1);
    expect(next.served, {SessionTypeId.s3});
  });

  test('completing the pointer type advances to the next unserved type, skipping served ones', () {
    const state = QueueState(pointer: SessionTypeId.s1, served: {SessionTypeId.s2});
    final next = engine.advance(state, SessionTypeId.s1);
    expect(next.pointer, SessionTypeId.s3); // s2 already served, skip it
  });

  test('serving all five types resets to a new cycle at S1', () {
    var state = const QueueState(pointer: SessionTypeId.s1, served: {});
    for (final id in [SessionTypeId.s1, SessionTypeId.s2, SessionTypeId.s3, SessionTypeId.s4]) {
      state = engine.advance(state, id);
    }
    expect(state.served.length, 4);
    final finalState = engine.advance(state, SessionTypeId.s5);
    expect(finalState.served, isEmpty);
    expect(finalState.pointer, SessionTypeId.s1);
  });

  test('time substitutions / readiness swaps grant no credit (null creditType is a no-op)', () {
    const state = QueueState(pointer: SessionTypeId.s3, served: {});
    final next = engine.advance(state, null);
    expect(next.pointer, state.pointer);
    expect(next.served, state.served);
  });
}
