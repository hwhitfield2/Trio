import 'package:flutter_test/flutter_test.dart';
import 'package:trio_follower/models/status_snapshot.dart';

/// The minimum a snapshot needs to parse at all, so each test can say only
/// what it is about.
Map<String, dynamic> snapshotJson(Map<String, dynamic> extra) => <String, dynamic>{
      'type': 'status',
      'timestamp': 1770000000,
      'units': 'mg/dL',
      'readings': <dynamic>[],
      ...extra,
    };

void main() {
  group('override presets', () {
    test('are read off the snapshot the host pushes', () {
      final snapshot = StatusSnapshot.fromJson(snapshotJson({
        'override_presets': [
          {'n': 'Sports', 'p': 70, 't': 140, 'd': 120},
          {'n': 'Sick day', 'p': 130, 't': 110, 'd': 720},
        ],
      }))!;

      expect(snapshot.overridePresets.length, 2);
      expect(snapshot.overridePresets.first.name, 'Sports');
      expect(snapshot.overridePresets.first.percentage, 70);
      expect(snapshot.overridePresets.first.targetMgdl, 140);
      expect(snapshot.overridePresets.first.durationMinutes, 120);
    });

    test('a preset needs a name — there is nothing to address it by without one', () {
      final snapshot = StatusSnapshot.fromJson(snapshotJson({
        'override_presets': [
          {'p': 70, 't': 140},
          {'n': '', 't': 140},
          {'n': 'Sports'},
        ],
      }))!;

      expect(snapshot.overridePresets.map((p) => p.name).toList(), ['Sports']);
    });

    test('the numbers are all optional: a bare name is still a preset', () {
      final snapshot = StatusSnapshot.fromJson(snapshotJson({
        'override_presets': [
          {'n': 'Sports'},
        ],
      }))!;

      final preset = snapshot.overridePresets.single;
      expect(preset.percentage, isNull);
      expect(preset.targetMgdl, isNull);
      expect(preset.durationMinutes, isNull);
    });

    test('a duration or target of zero is not one, so it is left off', () {
      final snapshot = StatusSnapshot.fromJson(snapshotJson({
        'override_presets': [
          {'n': 'Indefinite', 'p': 80, 't': 0, 'd': 0},
        ],
      }))!;

      final preset = snapshot.overridePresets.single;
      expect(preset.percentage, 80);
      expect(preset.targetMgdl, isNull);
      expect(preset.durationMinutes, isNull);
    });

    test('a host that sends none leaves the list empty rather than throwing', () {
      expect(StatusSnapshot.fromJson(snapshotJson({}))!.overridePresets, isEmpty);
      expect(
        StatusSnapshot.fromJson(snapshotJson({'override_presets': 'nope'}))!
            .overridePresets,
        isEmpty,
      );
      expect(
        StatusSnapshot.fromJson(snapshotJson({
          'override_presets': [42, null, 'x'],
        }))!
            .overridePresets,
        isEmpty,
      );
    });
  });

  group('temp target presets', () {
    test('are read off the snapshot, target and duration both required', () {
      final snapshot = StatusSnapshot.fromJson(snapshotJson({
        'temp_target_presets': [
          {'n': 'Exercise', 't': 140, 'd': 120},
          {'n': 'Pre-meal', 't': 80, 'd': 30},
          // No duration: a temp target that never ends is not one the follower
          // can offer, so it is dropped rather than guessed at.
          {'n': 'Broken', 't': 120},
          {'n': 'Also broken', 'd': 60},
        ],
      }))!;

      expect(
        snapshot.tempTargetPresets.map((p) => p.name).toList(),
        ['Exercise', 'Pre-meal'],
      );
      expect(snapshot.tempTargetPresets.first.targetMgdl, 140);
      expect(snapshot.tempTargetPresets.first.durationMinutes, 120);
    });

    test('a host that sends none leaves the list empty', () {
      expect(StatusSnapshot.fromJson(snapshotJson({}))!.tempTargetPresets, isEmpty);
    });
  });
}
