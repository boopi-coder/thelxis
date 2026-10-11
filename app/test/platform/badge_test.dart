import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:thelxis/platform/impl/badge_args.dart';
import 'package:thelxis/platform/impl/badge_impl.dart';
import 'package:thelxis/platform/session_badge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final since = DateTime.fromMillisecondsSinceEpoch(1760000123456, isUtc: true);
  final state = BadgeState(
    peers: const ['Alice', 'Bob'],
    label: '2 подключения',
    stopLabel: 'Отключить',
    since: since,
    controlActive: true,
  );

  group('encodeBadgeArgs', () {
    test('uses the documented keys and epoch milliseconds', () {
      final args = encodeBadgeArgs(state);
      expect(args.keys.toSet(), {
        'label',
        'stopLabel',
        'sinceMs',
        'controlActive',
        'peers',
      });
      expect(args['label'], '2 подключения');
      expect(args['stopLabel'], 'Отключить');
      expect(args['sinceMs'], 1760000123456);
      expect(args['controlActive'], true);
      expect(args['peers'], ['Alice', 'Bob']);
    });

    test('sinceMs does not depend on the DateTime being UTC or local', () {
      final local = DateTime.fromMillisecondsSinceEpoch(1760000123456);
      final other = BadgeState(
        peers: const [],
        label: 'x',
        stopLabel: 'y',
        since: local,
        controlActive: false,
      );
      expect(encodeBadgeArgs(other)['sinceMs'], 1760000123456);
    });

    test('peers are a copy that cannot be mutated', () {
      final peers = encodeBadgeArgs(state)['peers']! as List<String>;
      expect(() => peers.add('Eve'), throwsUnsupportedError);
    });

    test('every value is standard-codec encodable', () {
      const codec = StandardMethodCodec();
      final bytes = codec.encodeMethodCall(
        MethodCall('show', encodeBadgeArgs(state)),
      );
      final decoded = codec.decodeMethodCall(bytes);
      expect(decoded.method, 'show');
      expect((decoded.arguments as Map)['sinceMs'], 1760000123456);
    });
  });

  group('formatElapsed', () {
    test('HH:MM:SS with zero padding', () {
      expect(formatElapsed(Duration.zero), '00:00:00');
      expect(formatElapsed(const Duration(seconds: 59)), '00:00:59');
      expect(formatElapsed(const Duration(seconds: 61)), '00:01:01');
      expect(
        formatElapsed(const Duration(hours: 1, minutes: 2, seconds: 3)),
        '01:02:03',
      );
    });

    test('hours are not capped', () {
      expect(formatElapsed(const Duration(hours: 100)), '100:00:00');
    });

    test('sub-second remainders are truncated, negatives clamp to zero', () {
      expect(formatElapsed(const Duration(milliseconds: 1999)), '00:00:01');
      expect(formatElapsed(const Duration(seconds: -5)), '00:00:00');
    });
  });

  group('ChannelSessionBadge', () {
    const channel = MethodChannel(badgeChannelName);
    late List<MethodCall> calls;

    setUp(() {
      calls = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('show and dismiss reach the channel with the encoded state', () async {
      final badge = ChannelSessionBadge(channel: channel);
      await badge.show(state);
      await badge.dismiss();
      expect(calls.map((c) => c.method), ['show', 'dismiss']);
      expect((calls.first.arguments as Map)['label'], '2 подключения');
      expect(calls.last.arguments, isNull);
    });

    test('stopPressed from native fires stopRequests', () async {
      final badge = ChannelSessionBadge(channel: channel);
      final fired = Completer<void>();
      final sub = badge.stopRequests.listen((_) => fired.complete());

      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            badgeChannelName,
            const StandardMethodCodec().encodeMethodCall(
              const MethodCall('stopPressed'),
            ),
            (_) {},
          );

      await fired.future.timeout(const Duration(seconds: 2));
      await sub.cancel();
    });

    test(
      'a missing native side throws in production, is ignored in tests',
      () async {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
        final strict = ChannelSessionBadge(
          channel: channel,
          tolerateMissingNative: false,
        );
        await expectLater(
          strict.show(state),
          throwsA(isA<MissingPluginException>()),
        );
        final lenient = ChannelSessionBadge(
          channel: channel,
          tolerateMissingNative: true,
        );
        await lenient.show(state);
        await lenient.dismiss();
      },
    );

    test('native errors are surfaced to the caller', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            throw PlatformException(code: 'no_window', message: 'boom');
          });
      final badge = ChannelSessionBadge(channel: channel);
      expect(badge.show(state), throwsA(isA<PlatformException>()));
    });
  });
}
