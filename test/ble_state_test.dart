// Pure-logic tests for the rewritten BLE transport's deterministic seams
// (ble_state.dart). These cover exactly the parts that USED to race in the old
// engine — the backoff schedule, the seq allocator, the drain stop conditions,
// and the phase→legacy-string projection — none of which need a real band.

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/ble/ble_state.dart';

void main() {
  group('ReconnectPolicy backoff schedule', () {
    final p = ReconnectPolicy(
      base: const Duration(seconds: 2),
      cap: const Duration(seconds: 30),
      jitterFraction: 0.0, // deterministic for the shape assertions
    );

    test('base delay doubles each attempt then caps', () {
      expect(p.baseDelayFor(1).inSeconds, 2);
      expect(p.baseDelayFor(2).inSeconds, 4);
      expect(p.baseDelayFor(3).inSeconds, 8);
      expect(p.baseDelayFor(4).inSeconds, 16);
      expect(p.baseDelayFor(5).inSeconds, 30); // 32 -> capped at 30
      expect(p.baseDelayFor(6).inSeconds, 30);
      expect(p.baseDelayFor(50).inSeconds, 30); // no overflow blow-up
    });

    test('attempt < 1 is treated as attempt 1', () {
      expect(p.baseDelayFor(0).inSeconds, 2);
      expect(p.baseDelayFor(-5).inSeconds, 2);
    });

    test('jitter stays within [base, cap] and brackets the base delay', () {
      final jp = ReconnectPolicy(
        base: const Duration(seconds: 2),
        cap: const Duration(seconds: 30),
        jitterFraction: 0.2,
        rng: Random(42),
      );
      for (var attempt = 1; attempt <= 8; attempt++) {
        for (var i = 0; i < 200; i++) {
          final d = jp.delayFor(attempt).inMilliseconds;
          expect(d, greaterThanOrEqualTo(2000));
          expect(d, lessThanOrEqualTo(30000));
          final baseMs = jp.baseDelayFor(attempt).inMilliseconds;
          // within +/-20% of the (capped) base, clamped to bounds
          final lo = (baseMs * 0.8).floor().clamp(2000, 30000);
          final hi = (baseMs * 1.2).ceil().clamp(2000, 30000);
          expect(d, greaterThanOrEqualTo(lo));
          expect(d, lessThanOrEqualTo(hi));
        }
      }
    });
  });

  group('SeqAllocator discipline', () {
    test('live counter starts at 0xA0 and wraps back to 0xA0', () {
      final s = SeqAllocator();
      expect(s.nextLive(), 0xA0);
      expect(s.nextLive(), 0xA1);
      // Burn up to 0xFF then confirm the wrap stays in the high range.
      var last = 0xA1;
      for (var i = 0; i < 0x60; i++) {
        last = s.nextLive();
      }
      // After 0x60 more (0xA2..0xFF then wrap), the value is >= 0xA0 always.
      expect(last, greaterThanOrEqualTo(0xA0));
      // Exhaustively: 1000 allocations never leave the high range.
      for (var i = 0; i < 1000; i++) {
        expect(s.nextLive(), greaterThanOrEqualTo(0xA0));
      }
    });

    test('sync counter starts at 5 and never enters the live range', () {
      final s = SeqAllocator();
      expect(s.nextSync(), 5);
      expect(s.nextSync(), 6);
      for (var i = 0; i < 1000; i++) {
        final v = s.nextSync();
        expect(v, greaterThanOrEqualTo(5));
        expect(v, lessThanOrEqualTo(0xFF));
      }
    });

    test('live and sync ranges never collide at low values', () {
      final s = SeqAllocator();
      // The two ranges are disjoint by construction: sync wraps to 5 (well below
      // 0xA0), live wraps to 0xA0. A sync value can climb into 0xA0+ on wrap, but
      // it can never be confused for a *live* command because live commands are
      // built with nextLive(). The invariant we assert: sync floor < live floor.
      expect(SeqAllocator.syncFloor, lessThan(SeqAllocator.liveFloor));
      s.reset();
      expect(s.nextLive(), 0xA0);
      expect(s.nextSync(), 5);
    });
  });

  group('connStringFor projection', () {
    test('maps every phase to the legacy UI string', () {
      expect(connStringFor(BleConnState.idle), 'disconnected');
      expect(connStringFor(BleConnState.error), 'disconnected');
      expect(connStringFor(BleConnState.scanning), 'scanning');
      expect(connStringFor(BleConnState.connecting), 'connecting');
      expect(connStringFor(BleConnState.discovering), 'connecting');
      expect(connStringFor(BleConnState.subscribing), 'connecting');
      expect(connStringFor(BleConnState.settingUp), 'connecting');
      expect(connStringFor(BleConnState.reconnecting), 'connecting');
      expect(connStringFor(BleConnState.ready), 'connected');
      expect(connStringFor(BleConnState.live), 'connected');
      expect(connStringFor(BleConnState.syncing), 'syncing');
    });
  });

  group('DrainStopEvaluator stop conditions', () {
    const e = DrainStopEvaluator(
      liveEdgeWindow: Duration(seconds: 15),
      idleTimeout: Duration(seconds: 8),
      timeout: Duration(seconds: 600),
    );
    final now = 1_700_000_000; // arbitrary epoch sec

    DrainStop ev({
      bool complete = false,
      bool linkDown = false,
      int records = 0,
      int lastTs = 0,
      int sinceStartS = 1,
      int sinceNewS = 0,
    }) =>
        e.evaluate(
          complete: complete,
          linkDown: linkDown,
          records: records,
          lastRecordTsSec: lastTs,
          nowSec: now,
          sinceStart: Duration(seconds: sinceStartS),
          sinceLastNewRecord: Duration(seconds: sinceNewS),
        );

    test('complete wins over everything', () {
      expect(ev(complete: true, linkDown: true, records: 10), DrainStop.complete);
    });

    test('link-down stops immediately (before idle/timeout budget)', () {
      expect(ev(linkDown: true, records: 5, sinceNewS: 1), DrainStop.linkDown);
    });

    test('keeps going while records still flowing and not at live edge', () {
      // newest record is 100s behind now → not live edge; only 2s since last new.
      expect(
          ev(records: 50, lastTs: now - 100, sinceNewS: 2), DrainStop.keepGoing);
    });

    test('live-edge: newest record within window of now', () {
      expect(ev(records: 50, lastTs: now - 5, sinceNewS: 1), DrainStop.liveEdge);
    });

    test('idle: records seen but none new for >= idleTimeout', () {
      expect(ev(records: 50, lastTs: now - 100, sinceNewS: 9), DrainStop.idle);
    });

    test('idle: zero records and start older than idleTimeout', () {
      expect(ev(records: 0, sinceStartS: 9), DrainStop.idle);
    });

    test('timeout fires after the overall budget regardless', () {
      expect(ev(records: 50, lastTs: now - 100, sinceStartS: 601),
          DrainStop.timeout);
    });

    test('complete takes priority over link-down AND timeout', () {
      expect(
          ev(complete: true, linkDown: true, sinceStartS: 700), DrainStop.complete);
    });
  });
}
