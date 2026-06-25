// onehz_pipeline.dart — the PURE, isolate-safe analytics pipeline.
//
// `deriveDayBundle` is a top-level function with NO DB / IO / Flutter binding
// dependency, so it runs cleanly under `Isolate.run(...)` off the UI isolate.
// Heavy work (Lomb-Scargle 24-h spectra, van-Hees sleep windowing, autonomic
// staging) happens HERE, not on the main isolate.
//
// CROSSING THE ISOLATE BOUNDARY (copied, not shared):
//   IN  : DayInput.toJson()  — the day's 1 Hz numeric series + the Profile map.
//   OUT : Map<String,dynamic> — the full derived bundle (all metric families,
//         each value already shaped to the {value,confidence,tier,inputs_used}
//         envelope the UI's Metric.parse expects), PLUS the curve series the UI
//         needs (HR curve, HRV timeline, hypnogram) and indexed scalars.
//
// Everything in the OUT map is plain JSON (num/string/bool/list/map) so it
// survives `jsonEncode` into derived_day.payload_json.

import 'dart:math' as math;

import 'package:openstrap_analytics/onehz.dart';

/// Serializable input to the isolate: one physiological day's decoded 1 Hz
/// substrate + the user profile + baseline history needed for pass-2.
class DayInput {
  final String date; // display-only wake-to-wake label (edge-supplied)

  /// 1 Hz HR samples: parallel arrays. tsSec is epoch seconds; hr=0 => off-skin.
  final List<int> hrTsSec;
  final List<int> hrBpm;

  /// Beat-to-beat RR (ms) with the epoch-ms time of each beat's interval END.
  final List<double> rrTsMs;
  final List<double> rrMs;

  /// 1 Hz tri-axial accel (gravity vector, g).
  final List<double> accelTsSec;
  final List<double> ax;
  final List<double> ay;
  final List<double> az;

  /// Relative-ADC channels (raw counts; NO absolute units) sampled at the HR ts.
  final List<int> skinTempRaw;
  final List<int> spo2RedRaw;
  final List<int> spo2IrRaw;

  /// Profile (nullable fields) + trailing baseline history for pass-2.
  final Map<String, dynamic> profile;

  /// Trailing personal history (oldest→newest) the composite/readiness need.
  final List<double> lnRmssdHistory; // for Plews lnRMSSD readiness
  final List<double> rhrHistory; // RHR baseline window
  final List<double> respHistory; // resp-rate baseline
  final List<double> skinTempZHistory; // skin-temp deviation baseline

  const DayInput({
    required this.date,
    required this.hrTsSec,
    required this.hrBpm,
    required this.rrTsMs,
    required this.rrMs,
    required this.accelTsSec,
    required this.ax,
    required this.ay,
    required this.az,
    required this.skinTempRaw,
    required this.spo2RedRaw,
    required this.spo2IrRaw,
    required this.profile,
    this.lnRmssdHistory = const [],
    this.rhrHistory = const [],
    this.respHistory = const [],
    this.skinTempZHistory = const [],
  });

  Map<String, dynamic> toJson() => {
        'date': date,
        'hr_ts': hrTsSec,
        'hr': hrBpm,
        'rr_ts_ms': rrTsMs,
        'rr_ms': rrMs,
        'accel_ts': accelTsSec,
        'ax': ax,
        'ay': ay,
        'az': az,
        'skin_temp_raw': skinTempRaw,
        'spo2_red_raw': spo2RedRaw,
        'spo2_ir_raw': spo2IrRaw,
        'profile': profile,
        'ln_rmssd_history': lnRmssdHistory,
        'rhr_history': rhrHistory,
        'resp_history': respHistory,
        'skin_temp_z_history': skinTempZHistory,
      };

  static DayInput fromJson(Map<String, dynamic> m) {
    List<int> ints(String k) =>
        ((m[k] as List?) ?? const []).map((e) => (e as num).toInt()).toList();
    List<double> dbls(String k) =>
        ((m[k] as List?) ?? const []).map((e) => (e as num).toDouble()).toList();
    return DayInput(
      date: m['date'] as String,
      hrTsSec: ints('hr_ts'),
      hrBpm: ints('hr'),
      rrTsMs: dbls('rr_ts_ms'),
      rrMs: dbls('rr_ms'),
      accelTsSec: dbls('accel_ts'),
      ax: dbls('ax'),
      ay: dbls('ay'),
      az: dbls('az'),
      skinTempRaw: ints('skin_temp_raw'),
      spo2RedRaw: ints('spo2_red_raw'),
      spo2IrRaw: ints('spo2_ir_raw'),
      profile: ((m['profile'] as Map?) ?? const {}).cast<String, dynamic>(),
      lnRmssdHistory: dbls('ln_rmssd_history'),
      rhrHistory: dbls('rhr_history'),
      respHistory: dbls('resp_history'),
      skinTempZHistory: dbls('skin_temp_z_history'),
    );
  }
}

/// THE ISOLATE ENTRY POINT.
///
/// Pure: takes the serialized [DayInput] map, returns a plain JSON map (the full
/// derived bundle). Call directly + synchronously in tests, or via
/// `Isolate.run(() => deriveDayBundle(input))` in production.
Map<String, dynamic> deriveDayBundle(Map<String, dynamic> inputJson) {
  final d = DayInput.fromJson(inputJson);

  final hrAll = [for (var i = 0; i < d.hrBpm.length; i++) d.hrBpm[i].toDouble()];
  final hrValid = hrAll.where((h) => h > 0).toList();

  // ── FOUNDATION: clean the RR series (Lipponen–Tarvainen) ──────────────────
  final corrected = correctRr(d.rrMs);
  final nn = corrected.nn;
  final nnTimes = corrected.nnTimesMs;

  // ── accel samples + ENMO motion + sleep windowing ─────────────────────────
  final accel = <AccelSample>[
    for (var i = 0; i < d.ax.length; i++)
      AccelSample(d.accelTsSec[i] * 1000.0, d.ax[i], d.ay[i], d.az[i])
  ];

  // ── SLEEP: van Hees window → immobility mask → autonomic stager ───────────
  final sleepWin = vanHeesSleepWindow(accel);
  final immobile = sleepWin.present ? sleepWin.value!.immobile : <bool>[];

  // HR aligned to the accel/sleep timeline for the stager (needs equal-length-ish
  // per-second HR + immobility). We use the valid-or-zero HR stream as-is.
  final stager = (immobile.isNotEmpty && hrAll.isNotEmpty)
      ? autonomicStager(hrAll, immobile)
      : Metric<StagerResult>.absent(
          tier: Tier.estimate, inputs_used: const ['hr_1hz', 'immobility']);

  // Build the asleep mask from the sleep window for sleep accounting.
  final asleep = <bool>[];
  if (sleepWin.present) {
    final w = sleepWin.value!;
    for (var i = 0; i < w.immobile.length; i++) {
      asleep.add(i >= w.onsetIdx && i < w.offsetIdx && w.immobile[i]);
    }
  }
  // Map per-epoch stages onto the sleep-window seconds for the hypnogram.
  List<SleepStage>? stages;
  if (stager.present && asleep.isNotEmpty) {
    final s = stager.value!;
    final epoch = s.epochSec;
    stages = <SleepStage>[
      for (var i = 0; i < asleep.length; i++)
        (i ~/ epoch) < s.stages.length ? s.stages[i ~/ epoch] : SleepStage.wake
    ];
  }
  final sleepAcct = asleep.isNotEmpty
      ? sleepAccounting(asleep, stages: stages)
      : Metric<SleepAccounting>.absent(
          tier: Tier.estimate, inputs_used: const ['asleep_mask']);

  // ── split HR into night (during sleep window) vs day for the dip ──────────
  final nightHr = <double>[];
  final dayHr = <double>[];
  if (sleepWin.present) {
    final w = sleepWin.value!;
    for (var i = 0; i < hrAll.length; i++) {
      if (i >= w.onsetIdx && i < w.offsetIdx) {
        nightHr.add(hrAll[i]);
      } else {
        dayHr.add(hrAll[i]);
      }
    }
  } else {
    dayHr.addAll(hrAll);
  }

  // ── CLINICAL ───────────────────────────────────────────────────────────────
  final hrvT = hrvTime(nn, nnTimesMs: nnTimes);
  final hrvF = nn.length >= 20
      ? hrvFreq(nn, nnTimes,
          artifactFraction: (1.0 - corrected.cleanFraction).clamp(0.0, 1.0))
      : Metric<HrvFreq>.absent(tier: Tier.high, inputs_used: const ['rr_cleaned']);
  final rhr = nocturnalRhr(nightHr.isNotEmpty ? nightHr : hrValid);
  final dip = hrDip(dayHr, nightHr);
  final dc = decelerationCapacity(nn);
  final ac = accelerationCapacity(nn);

  // ── RESPIRATION ──────────────────────────────────────────────────────────
  final artifactFraction = (1.0 - corrected.cleanFraction).clamp(0.0, 1.0);
  final resp = nn.length >= 30
      ? rsaRespRate(nn, nnTimes, artifactFraction: artifactFraction)
      : Metric<RespEstimate>.absent(
          tier: Tier.estimate, inputs_used: const ['rr_cleaned']);
  final cvhr = nn.length >= 60
      ? cvhrApneaScreen(nn, nnTimes, artifactFraction: artifactFraction)
      : Metric<CvhrResult>.absent(
          tier: Tier.estimate, inputs_used: const ['rr_cleaned']);

  // Relative ODI (desaturation-event SCREEN). red/ir/ts are appended 1:1 per R24
  // alongside HR, so they share length; guard equality defensively anyway.
  final odiRed = [for (final v in d.spo2RedRaw) v.toDouble()];
  final odiIr = [for (final v in d.spo2IrRaw) v.toDouble()];
  final odiTs = [for (final v in d.hrTsSec) v.toDouble()];
  final odi = (odiRed.length == odiIr.length &&
          odiRed.length == odiTs.length &&
          odiRed.length >= 60)
      ? relativeOdi(odiRed, odiIr, odiTs)
      : Metric<RelativeOdiResult>.absent(
          tier: Tier.relative,
          inputs_used: const ['spo2_red_raw', 'spo2_ir_raw']);

  // Cardiopulmonary coupling (sleep-stability screen) from the cleaned NN series.
  final cpc = nn.length >= 60
      ? cardiopulmonaryCoupling(nn, nnTimes)
      : Metric<CpcResult>.absent(
          tier: Tier.high, inputs_used: const ['rr_cleaned']);

  // ── MOTION (ENMO + sleep position) ─────────────────────────────────────────
  final accelMags =
      accel.map((s) => math.sqrt(s.x * s.x + s.y * s.y + s.z * s.z)).toList();
  final enmo = accel.length >= 60
      ? enmoSeries(accel)
      : EnmoResult(1.0, const [], 0.0);
  // Sleep position: tilt over the sleep window (a representative still epoch).
  Metric<Tilt> position = Metric<Tilt>.absent(
      tier: Tier.estimate, inputs_used: const ['accel_1hz']);
  if (sleepWin.present && accel.length >= 30) {
    final w = sleepWin.value!;
    final lo = w.onsetIdx.clamp(0, accel.length - 1);
    final hi = (w.onsetIdx + 60).clamp(lo + 1, accel.length);
    position = staticTilt(accel.sublist(lo, hi));
  }

  // ── WELLNESS: relative skin-temp deviation (z) from this night's mean ──────
  // RELATIVE only — raw ADC, never an absolute °C.
  double? skinTempZ;
  final tempValid = d.skinTempRaw.where((v) => v > 0).map((v) => v.toDouble()).toList();
  if (tempValid.length >= 60 && d.skinTempZHistory.length >= 3) {
    final m = _mean(tempValid)!;
    final base = _mean(d.skinTempZHistory)!;
    final sd = _stddev(d.skinTempZHistory);
    if (sd != null && sd > 0) skinTempZ = (m - base) / sd;
  }

  // ── PASS-2: baseline-dependent readiness ──────────────────────────────────
  // lnRMSSD readiness (Plews) over the trailing history INCLUDING today.
  final lnHist = [...d.lnRmssdHistory];
  final lnToday = (hrvT.present && hrvT.value!.rmssd != null && hrvT.value!.rmssd! > 0)
      ? math.log(hrvT.value!.rmssd!)
      : null;
  if (lnToday != null) lnHist.add(lnToday);
  final lnReadiness = lnHist.length >= 4
      ? readinessLnRmssd(lnHist)
      : Metric<ReadinessLnRmssd>.absent(
          tier: Tier.high, inputs_used: const ['ln_rmssd_history']);

  // Composite readiness (HRV ∩ RHR ∩ RR ∩ temp) using stored baselines.
  final rhrToday = rhr.present ? rhr.value!.low30Mean : null;
  final respToday = resp.present ? resp.value!.brpm : null;
  final composite = readinessComposite([
    hrvInput(lnToday, d.lnRmssdHistory),
    rhrInput(rhrToday, d.rhrHistory),
    respInput(respToday, d.respHistory),
    tempInput(skinTempZ, d.skinTempZHistory),
  ]);

  // ── LOAD: Banister TRIMP (needs HRmax + RHR + sex from the profile) ───────
  final prof = d.profile;
  final age = (prof['age'] as num?)?.toDouble();
  final sex = (prof['sex'] as String?)?.toLowerCase();
  final hrMax = age == null ? null : 208 - 0.7 * age; // Tanaka
  final rhrForTrimp = rhrToday ?? (prof['resting_hr'] as num?)?.toDouble();
  Metric<double> trimp = Metric<double>.absent(
      tier: Tier.estimate, inputs_used: const ['hr_1hz', 'profile']);
  if (hrMax != null && rhrForTrimp != null && sex != null && hrValid.isNotEmpty) {
    // Per-minute mean HR for the day.
    final perMin = _perMinuteMean(d.hrTsSec, d.hrBpm);
    if (perMin.isNotEmpty) {
      trimp = banisterTrimp(perMin,
          restingHr: rhrForTrimp,
          maxHr: hrMax,
          sex: sex == 'f' ? Sex.female : Sex.male);
    }
  }

  // ── HR curve (downsampled to ~per-minute) + HRV timeline + hypnogram ──────
  final hrCurve = _downsampleHr(d.hrTsSec, d.hrBpm);
  final hypnogram = _hypnogram(sleepWin, stages, d.accelTsSec);
  final hrvTimeline = _hrvTimeline(nn, nnTimes);

  // ── ASSEMBLE bundle (all envelopes are plain JSON via Metric.toJson) ───────
  final clinical = <String, dynamic>{
    'hrv_time': hrvT.toJson((v) => v.toJson()),
    'hrv_freq': hrvF.toJson((v) => v.toJson()),
    'resting_hr': rhr.toJson((v) => v.toJson()),
    'hr_dip': dip.toJson((v) => v.toJson()),
    'prsa_dc': dc.toJson((v) => v.toJson()),
    'prsa_ac': ac.toJson((v) => v.toJson()),
    'readiness_lnrmssd': lnReadiness.toJson((v) => v.toJson()),
    'readiness_composite': composite.toJson((v) => v.toJson()),
    'trimp': trimp.toJson(),
  };
  final sleep = <String, dynamic>{
    'window': sleepWin.toJson((v) => v.toJson()),
    'accounting': sleepAcct.toJson((v) => v.toJson()),
    'stager': stager.toJson((v) => v.toJson()),
    'cpc': cpc.toJson((v) => v.toJson()),
  };
  final respiration = <String, dynamic>{
    'rsa': resp.toJson((v) => v.toJson()),
    'cvhr_apnea': cvhr.toJson((v) => v.toJson()),
    'odi': odi.toJson((v) => v.toJson()),
  };
  final motion = <String, dynamic>{
    'enmo_coverage': enmo.coverage,
    'enmo_minutes': enmo.minutes.length,
    'mean_enmo': _mean(enmo.minutes.map((m) => m.enmo).toList()),
    'mean_mag': _mean(accelMags),
    'sleep_position': position.toJson((v) => v.toJson()),
  };
  final wellness = <String, dynamic>{
    'skin_temp': {
      'value': skinTempZ == null ? '—' : _round(skinTempZ, 4),
      'confidence': skinTempZ == null ? 0 : 0.5,
      'tier': Tier.relative,
      'inputs_used': const ['skin_temp_raw'],
      'note': 'relative deviation (z) vs your baseline; raw ADC, no absolute °C',
    },
  };

  // Scalars to index for trends.
  final rhrScalar = rhr.present ? rhr.value!.low30Mean : null;
  final rmssdScalar =
      (hrvT.present && hrvT.value!.rmssd != null) ? hrvT.value!.rmssd : null;
  final readinessScalar = composite.present ? composite.value!.score : null;

  return <String, dynamic>{
    'date': d.date,
    'clinical': clinical,
    'sleep': sleep,
    'respiration': respiration,
    'motion': motion,
    'wellness': wellness,
    // Curve series for the UI.
    'series': {
      'hr_curve': hrCurve,
      'hrv_timeline': hrvTimeline,
      'hypnogram': hypnogram,
    },
    // Coverage diagnostics.
    'coverage': {
      'hr_samples': hrAll.length,
      'hr_valid': hrValid.length,
      'rr_beats': d.rrMs.length,
      'nn_clean': nn.length,
      'clean_fraction': _round(corrected.cleanFraction, 4),
      'accel_samples': accel.length,
    },
    // Indexed scalars (also surfaced to columns + metric_series by the engine).
    'scalars': {
      'rhr': rhrScalar,
      'rmssd': rmssdScalar,
      'readiness': readinessScalar,
      'ln_rmssd': lnToday,
      'resp_rate': respToday,
      'skin_temp_z': skinTempZ,
      'sdnn': hrvT.present ? hrvT.value!.sdnn : null,
      'dip_pct': dip.present ? dip.value!.dipPct : null,
      'trimp': trimp.present ? trimp.value : null,
      'odi_per_hour': odi.present ? odi.value!.odiPerHour : null,
      'cpc_ratio': cpc.present ? cpc.value!.cpcRatio : null,
    },
  };
}

// ── helpers (pure) ───────────────────────────────────────────────────────────

double? _mean(List<double> xs) {
  if (xs.isEmpty) return null;
  var s = 0.0;
  for (final x in xs) {
    s += x;
  }
  return s / xs.length;
}

double? _stddev(List<double> xs) {
  if (xs.length < 2) return null;
  final m = _mean(xs)!;
  var s = 0.0;
  for (final x in xs) {
    s += (x - m) * (x - m);
  }
  return math.sqrt(s / (xs.length - 1));
}

double _round(double v, int dp) {
  final p = math.pow(10, dp);
  return (v * p).round() / p;
}

/// Per-minute mean HR (valid only), in chronological minute order.
List<double> _perMinuteMean(List<int> tsSec, List<int> hr) {
  final buckets = <int, List<double>>{};
  for (var i = 0; i < hr.length; i++) {
    if (hr[i] <= 0) continue;
    final min = tsSec[i] ~/ 60;
    (buckets[min] ??= []).add(hr[i].toDouble());
  }
  final keys = buckets.keys.toList()..sort();
  return [for (final k in keys) _mean(buckets[k]!)!];
}

/// HR curve downsampled to ~per-minute {t: epochSec, v: bpm} (valid only).
List<Map<String, num>> _downsampleHr(List<int> tsSec, List<int> hr) {
  final buckets = <int, List<double>>{};
  for (var i = 0; i < hr.length; i++) {
    if (hr[i] <= 0) continue;
    final min = tsSec[i] ~/ 60;
    (buckets[min] ??= []).add(hr[i].toDouble());
  }
  final keys = buckets.keys.toList()..sort();
  return [
    for (final k in keys) {'t': k * 60, 'v': _mean(buckets[k]!)!.round()}
  ];
}

/// HRV timeline: RMSSD over rolling ~5-min windows of cleaned NN, {t, v}.
List<Map<String, num>> _hrvTimeline(List<double> nn, List<double> nnTimes) {
  if (nn.length < 10 || nnTimes.length != nn.length) return const [];
  const winMs = 300000.0; // 5 min
  final out = <Map<String, num>>[];
  var lo = 0;
  for (var i = 0; i < nn.length; i++) {
    while (nnTimes[i] - nnTimes[lo] > winMs) {
      lo++;
    }
    if (i - lo >= 10) {
      var ssd = 0.0;
      for (var k = lo + 1; k <= i; k++) {
        final diff = nn[k] - nn[k - 1];
        ssd += diff * diff;
      }
      final rmssd = math.sqrt(ssd / (i - lo));
      // Emit one point per ~minute to keep the series small.
      if (out.isEmpty || nnTimes[i] - out.last['t']! * 1000 > 60000) {
        out.add({'t': (nnTimes[i] / 1000).round(), 'v': _round(rmssd, 1)});
      }
    }
  }
  return out;
}

/// Hypnogram stage segments: {start, end, stage} (epoch seconds), display-ready.
List<Map<String, dynamic>> _hypnogram(
    Metric<SleepWindow> win, List<SleepStage>? stages, List<double> accelTsSec) {
  if (!win.present || stages == null || stages.isEmpty || accelTsSec.isEmpty) {
    return const [];
  }
  final w = win.value!;
  final t0 = w.onsetMs != null
      ? (w.onsetMs! / 1000).round()
      : (accelTsSec.first.round());
  final segs = <Map<String, dynamic>>[];
  String label(SleepStage s) => s == SleepStage.wake
      ? 'wake'
      : (s == SleepStage.rem ? 'rem' : 'nrem');
  int? segStart;
  SleepStage? cur;
  for (var i = w.onsetIdx; i < w.offsetIdx && i < stages.length; i++) {
    final s = stages[i];
    if (cur == null) {
      cur = s;
      segStart = i;
    } else if (s != cur) {
      segs.add({
        'start': t0 + (segStart! - w.onsetIdx),
        'end': t0 + (i - w.onsetIdx),
        'stage': label(cur),
      });
      cur = s;
      segStart = i;
    }
  }
  if (cur != null && segStart != null) {
    segs.add({
      'start': t0 + (segStart - w.onsetIdx),
      'end': t0 + (w.offsetIdx - w.onsetIdx),
      'stage': label(cur),
    });
  }
  return segs;
}
