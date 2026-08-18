import 'package:flutter_test/flutter_test.dart';
import 'package:trio_follower/services/sync_scheduler.dart';

void main() {
  final now = DateTime.utc(2025, 1, 1, 12);

  group('SyncScheduler', () {
    test('stays quiet while pushes keep the snapshot fresh', () {
      final scheduler = SyncScheduler();
      expect(
        scheduler.shouldRequest(now: now, snapshotAt: now.subtract(const Duration(minutes: 4))),
        isFalse,
      );
    });

    test('asks once the snapshot is older than a CGM cycle', () {
      final scheduler = SyncScheduler();
      expect(
        scheduler.shouldRequest(now: now, snapshotAt: now.subtract(const Duration(minutes: 7))),
        isTrue,
      );
    });

    test('asks when there is no snapshot at all', () {
      final scheduler = SyncScheduler();
      expect(scheduler.shouldRequest(now: now, snapshotAt: null), isTrue);
    });

    test('does not ask again inside the minimum interval', () {
      final scheduler = SyncScheduler();
      scheduler.recordRequest(now);

      expect(scheduler.shouldRequest(now: now.add(const Duration(minutes: 1)), snapshotAt: null), isFalse);
      expect(scheduler.shouldRequest(now: now.add(const Duration(minutes: 6)), snapshotAt: null), isTrue);
    });

    test('backs off while the host stays silent, and recovers on an answer', () {
      final scheduler = SyncScheduler();
      expect(scheduler.retryInterval, const Duration(minutes: 5));

      scheduler.recordFailure();
      expect(scheduler.retryInterval, const Duration(minutes: 10));
      scheduler.recordFailure();
      expect(scheduler.retryInterval, const Duration(minutes: 20));

      // A third failure would be 40 minutes; the cap holds it at 30.
      scheduler.recordFailure();
      expect(scheduler.retryInterval, const Duration(minutes: 30));
      scheduler.recordFailure();
      expect(scheduler.retryInterval, const Duration(minutes: 30));

      scheduler.recordSuccess();
      expect(scheduler.retryInterval, const Duration(minutes: 5));
    });

    test('honours the widened interval after a failure', () {
      final scheduler = SyncScheduler();
      scheduler.recordRequest(now);
      scheduler.recordFailure();

      expect(scheduler.shouldRequest(now: now.add(const Duration(minutes: 6)), snapshotAt: null), isFalse);
      expect(scheduler.shouldRequest(now: now.add(const Duration(minutes: 11)), snapshotAt: null), isTrue);
    });

    test('reset forgets the request history', () {
      final scheduler = SyncScheduler();
      scheduler.recordRequest(now);
      scheduler.recordFailure();
      scheduler.reset();

      expect(scheduler.retryInterval, const Duration(minutes: 5));
      expect(scheduler.shouldRequest(now: now, snapshotAt: null), isTrue);
    });

    test('treats a snapshot timestamped in the future as fresh', () {
      // Host clocks can run slightly ahead; that is not a reason to poll.
      final scheduler = SyncScheduler();
      expect(
        scheduler.shouldRequest(now: now, snapshotAt: now.add(const Duration(minutes: 2))),
        isFalse,
      );
    });
  });
}
