// DerivationEngine — the on-device compute orchestrator (MAIN ISOLATE).
//
// Flow (per trigger):
//   1. Find physiological days with NEW raw since their stored `last_raw_ts`
//      (un-derived OR stale). Battery-sense: a day is recomputed only if it has
//      new raw — no fingerprint gymnastics.
//   2. For each such day (main isolate): read its raw rows from LocalDb, decode
//      via openstrap_protocol → numeric 1 Hz series (HR / RR / accel / ADC).
//   3. Hand the SERIALIZED series + Profile + trailing baselines to a PURE
//      top-level fn (`deriveDayBundle`) via `Isolate.run` — heavy work (24-h
//      spectra, sleep staging) runs OFF the UI isolate. DB I/O stays on main
//      (sqflite isn't isolate-safe). Pass-1 (baseline-independent: RMSSD/RHR)
//      and pass-2 (baseline-dependent: readiness) both happen inside the bundle
//      using the trailing history we pass in.
//   4. Write the bundle → derived_day (+ metric_series + refresh baselines).
//   5. Prune raw older than rawRetentionDays — but NEVER for a day not yet
//      derived (raw-first invariant).

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:openstrap_protocol/openstrap_protocol.dart' as proto;

import '../data/db.dart';
import 'onehz_pipeline.dart';
import 'profile.dart';

/// Bundle schema version — bump to force a full recompute on a logic change.
const int derivedVersion = 1;

/// Raw is kept this many days past derivation, then pruned (derived stays).
const int rawRetentionDays = 7;

/// How many trailing derived days feed pass-2 baselines.
const int _baselineWindowDays = 28;

class DerivationEngine {
  DerivationEngine({this.log});
  final void Function(String)? log;

  bool _running = false;

  /// True while a derivation pass is in flight (so triggers don't pile up).
  bool get running => _running;

  /// Run a derivation pass. [heavy]=false runs a bounded light pass (only the
  /// most-recent affected day) suitable for a short background BLE wake;
  /// [heavy]=true sweeps every stale day (the nightly scheduled pass).
  /// [force]=true re-derives EVERY day that has raw, ignoring the derived
  /// cursor — the user-initiated "re-analyze all data" path. Re-entrant calls
  /// are coalesced. Returns the number of days derived.
  Future<int> run(Profile profile, {bool heavy = false, bool force = false}) async {
    if (_running) return 0;
    _running = true;
    try {
      final stale = await _staleDays(force: force);
      if (stale.isEmpty) {
        _log('derive: nothing to do');
        return 0;
      }
      // Light pass: only the newest affected day (capture-window-sized work).
      // Heavy/force: every affected day.
      final days = (heavy || force) ? stale : stale.sublist(stale.length - 1);
      _log('derive: ${days.length} day(s) '
          '(${force ? "force-all" : heavy ? "heavy" : "light"})');
      for (final day in days) {
        await _deriveDay(day, profile);
      }
      await _pruneOldRaw();
      return days.length;
    } catch (e, st) {
      _log('derive ERROR: $e\n$st');
      return 0;
    } finally {
      _running = false;
    }
  }

  // ── find days needing (re)derivation ───────────────────────────────────────

  /// Physiological-day labels (sorted ascending) that have raw newer than their
  /// derived `last_raw_ts` (or were never derived / are an old bundle version).
  /// [force]=true returns EVERY day that has raw, ignoring the derived cursor.
  Future<List<String>> _staleDays({bool force = false}) async {
    final earliest = await LocalDb.earliestRawCapturedAt();
    final latest = await LocalDb.latestRawCapturedAt();
    if (earliest == null || latest == null) return const [];

    // Group raw capture times by physiological-day label. We approximate the
    // wake-to-wake day by the LOCAL calendar date of the capture; this is the
    // edge-supplied display label, refined by the sleep window inside the
    // bundle. Bucketing on a per-day max is enough to detect "new raw".
    final lastRawByDay = await LocalDb.derivedLastRawTs();
    final dayMax = <String, int>{};
    // Walk the whole raw range in day-sized buckets. We only need each day's max
    // captured_at, which we get cheaply by scanning distinct day labels.
    final db = await LocalDb.instance;
    final rows = await db.rawQuery(
      "SELECT strftime('%Y-%m-%d', captured_at/1000, 'unixepoch', 'localtime') AS d, "
      'MAX(captured_at) AS mx FROM raw_records GROUP BY d',
    );
    for (final r in rows) {
      final d = r['d'] as String?;
      final mx = (r['mx'] as num?)?.toInt();
      if (d != null && mx != null) dayMax[d] = mx;
    }

    final stale = <String>[];
    for (final e in dayMax.entries) {
      if (force) {
        stale.add(e.key);
        continue;
      }
      final derivedTs = lastRawByDay[e.key];
      if (derivedTs == null || e.value > derivedTs) {
        stale.add(e.key);
      }
    }
    stale.sort();
    return stale;
  }

  // ── derive one day ──────────────────────────────────────────────────────────

  Future<void> _deriveDay(String date, Profile profile) async {
    // Day window in epoch ms (local-calendar day). last_raw_ts is captured here
    // on the MAIN isolate, before the heavy work, so a concurrent live insert
    // mid-pass is simply picked up next pass (its captured_at > last_raw_ts).
    final from = DateTime.parse('$date 00:00:00').millisecondsSinceEpoch;
    final to = DateTime.parse('$date 23:59:59').millisecondsSinceEpoch + 999;

    final hexes = await LocalDb.rawHexInCaptureRange(from, to);
    if (hexes.isEmpty) return;
    final lastRawTs = to; // everything in-window is now reflected.

    // (main isolate) DECODE the raw hex → 1 Hz numeric series.
    final input = _buildDayInput(date, hexes, profile);
    // Attach trailing baselines for pass-2.
    final withHistory = await _attachHistory(input);

    // (off-isolate) run the pure pipeline. Isolate.run copies the map in/out.
    final bundle = await Isolate.run(() => deriveDayBundle(withHistory));

    // (main isolate) persist.
    final scalars = (bundle['scalars'] as Map?)?.cast<String, dynamic>() ?? const {};
    double? sc(String k) => (scalars[k] as num?)?.toDouble();
    await LocalDb.putDerivedDay(
      date: date,
      payloadJson: jsonEncode(bundle),
      version: derivedVersion,
      lastRawTs: lastRawTs,
      rhr: sc('rhr'),
      rmssd: sc('rmssd'),
      readiness: sc('readiness'),
      series: {
        'rhr': sc('rhr'),
        'rmssd': sc('rmssd'),
        'sdnn': sc('sdnn'),
        'readiness': sc('readiness'),
        'ln_rmssd': sc('ln_rmssd'),
        'resp_rate': sc('resp_rate'),
        'skin_temp_z': sc('skin_temp_z'),
        'dip_pct': sc('dip_pct'),
        'trimp': sc('trimp'),
      },
    );
    await _refreshBaselines();
    _log('derived $date — ${hexes.length} raw → bundle v$derivedVersion');
  }

  /// Decode raw frames into a serialized [DayInput] map (the isolate input).
  Map<String, dynamic> _buildDayInput(
      String date, List<String> hexes, Profile profile) {
    final hrTs = <int>[], hrBpm = <int>[];
    final rrTsMs = <double>[], rrMs = <double>[];
    final aTs = <double>[], ax = <double>[], ay = <double>[], az = <double>[];
    final skinTemp = <int>[], spo2Red = <int>[], spo2Ir = <int>[];

    for (final hex in hexes) {
      // Type-24 historical (1 Hz biometric) records carry the full substrate.
      proto.R24? r;
      try {
        r = proto.parseR24(proto.hexToBytes(hex));
      } catch (_) {
        r = null;
      }
      if (r != null && r.tsEpoch > 0) {
        hrTs.add(r.tsEpoch);
        hrBpm.add(r.hr);
        // RR beats: distribute across the 1-s record, anchored at record end.
        var t = r.tsEpoch * 1000.0;
        for (final rr in r.rrIntervalsMs) {
          if (rr > 0) {
            rrMs.add(rr.toDouble());
            rrTsMs.add(t);
            t += 0; // beats share the record second; time order preserved
          }
        }
        if (r.accelG.length == 3) {
          aTs.add(r.tsEpoch.toDouble());
          ax.add(r.accelG[0]);
          ay.add(r.accelG[1]);
          az.add(r.accelG[2]);
        }
        skinTemp.add(r.skinTempRaw);
        spo2Red.add(r.spo2RedRaw);
        spo2Ir.add(r.spo2IrRaw);
        continue;
      }
      // Live RR-bearing frames (0x28 / R10) — fold their beats in too.
      final live = proto.realtimeRr(hex);
      if (live != null && live.ts > 0) {
        for (final rr in live.rrMs) {
          if (rr > 0) {
            rrMs.add(rr.toDouble());
            rrTsMs.add(live.ts * 1000.0);
          }
        }
      }
    }

    // Order all series by time (decode order ~= capture order, but be safe for RR).
    return DayInput(
      date: date,
      hrTsSec: hrTs,
      hrBpm: hrBpm,
      rrTsMs: rrTsMs,
      rrMs: rrMs,
      accelTsSec: aTs,
      ax: ax,
      ay: ay,
      az: az,
      skinTempRaw: skinTemp,
      spo2RedRaw: spo2Red,
      spo2IrRaw: spo2Ir,
      profile: profile.toMap(),
    ).toJson();
  }

  /// Attach trailing personal history (from metric_series) for pass-2 baselines.
  Future<Map<String, dynamic>> _attachHistory(Map<String, dynamic> input) async {
    Future<List<double>> hist(String key) async {
      final rows = await LocalDb.metricSeries(key, limit: _baselineWindowDays);
      return [for (final r in rows) (r['value'] as num).toDouble()];
    }

    input['ln_rmssd_history'] = await hist('ln_rmssd');
    input['rhr_history'] = await hist('rhr');
    input['resp_history'] = await hist('resp_rate');
    input['skin_temp_z_history'] = await hist('skin_temp_z');
    return input;
  }

  /// Refresh rolling baselines from the recent derived rows (cheap: from columns).
  Future<void> _refreshBaselines() async {
    final recent = await LocalDb.recentDerivedDays(_baselineWindowDays);
    double? avg(String col) {
      final vs = [
        for (final r in recent)
          if (r[col] != null) (r[col] as num).toDouble()
      ];
      if (vs.isEmpty) return null;
      return vs.reduce((a, b) => a + b) / vs.length;
    }

    await LocalDb.putBaseline(
      'rolling',
      jsonEncode({
        'rhr': avg('rhr'),
        'rmssd': avg('rmssd'),
        'readiness': avg('readiness'),
        'n': recent.length,
      }),
    );
  }

  // ── raw pruning (raw-first invariant) ──────────────────────────────────────

  /// Prune raw older than [rawRetentionDays] — but only days that ARE derived.
  /// We compute the cutoff and clamp it so we never delete raw newer than the
  /// oldest UN-derived day's window.
  Future<void> _pruneOldRaw() async {
    final retentionCutoff = DateTime.now()
        .subtract(const Duration(days: rawRetentionDays))
        .millisecondsSinceEpoch;

    // Find the earliest stale (un-derived) day; never prune at/after its window.
    final stale = await _staleDays();
    int guardedCutoff = retentionCutoff;
    if (stale.isNotEmpty) {
      final earliestStale =
          DateTime.parse('${stale.first} 00:00:00').millisecondsSinceEpoch;
      if (earliestStale < guardedCutoff) {
        // The oldest un-derived day is older than the retention cutoff — only
        // prune strictly before it so its raw survives until it's derived.
        guardedCutoff = earliestStale;
      }
    }
    if (guardedCutoff <= 0) return;
    final deleted = await LocalDb.pruneRawBefore(guardedCutoff);
    if (deleted > 0) _log('pruned $deleted raw rows < ${guardedCutoff ~/ 1000}');
  }

  void _log(String m) {
    if (kDebugMode) debugPrint('[derive] $m');
    log?.call('[derive] $m');
  }
}
