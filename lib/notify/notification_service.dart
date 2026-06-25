// notification_service.dart — the ONE place OS-level notifications are presented.
//
// Today it serves local, on-device triggers (band battery low / charging, see
// device_alerts.dart). It is deliberately source-agnostic so a future push
// system (Firebase Cloud Messaging / APNs) is plug-and-play and CANNOT collide
// with what we ship now:
//
//   • Channels are partitioned by source. Device alerts live on `device_alerts`.
//     A future server/push layer gets its own `insights` channel (id reserved
//     below) — created by that layer when it lands, so the two never share one.
//   • Notification IDs are partitioned. Device alerts use fixed ids < kServerIdBase;
//     server/push notifications must start at kServerIdBase so neither overwrites
//     the other.
//   • One init, one permission prompt. FCM would call show(...) here to display
//     foreground messages and reuse ensurePermission() — no second plugin setup.
//
// flutter_local_notifications coexists with firebase_messaging by design: FCM
// delivers, this displays. Nothing here imports or assumes Firebase.

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _inited = false;
  bool? _granted;

  // ── Channels (one per source — keep them disjoint) ──────────────────────────
  static const AndroidNotificationChannel _deviceChannel =
      AndroidNotificationChannel(
    'device_alerts',
    'Device alerts',
    description: 'Band battery and charging',
    importance: Importance.high,
  );

  /// Insights channel — locally-generated, derive-driven nudges (recovery ready,
  /// wind-down, weekly recap). Disjoint from device alerts so the two never share
  /// a channel or an id range.
  static const AndroidNotificationChannel _insightsChannel =
      AndroidNotificationChannel(
    'insights',
    'Insights',
    description: 'Recovery, sleep and weekly summaries from your own data',
    importance: Importance.defaultImportance,
  );
  static const String insightsChannelId = 'insights';

  // Stable insight notification ids (≥ kServerIdBase; never collide w/ device).
  static const int idRecoveryReady = 2001;
  static const int idWindDown = 2002;
  static const int idWeeklyRecap = 2003;

  // ── Notification id space (never reuse an id across sources) ─────────────────
  static const int idLowBattery = 1001;
  static const int idCharging = 1002;

  /// Server/push notifications MUST start here so they can't overwrite a device
  /// alert (and vice-versa). e.g. `kServerIdBase + serverNotifId.hashCode % 100000`.
  static const int kServerIdBase = 2000;

  /// Set up the plugin + the device-alerts channel. Idempotent. Does NOT prompt.
  Future<void> init() async {
    if (_inited) return;
    // Use the real launcher mipmap — the project renamed it to `launcher_icon`
    // (see AndroidManifest android:icon), so the Flutter-default `ic_launcher`
    // no longer resolves and made initialize() throw `invalid_icon` in release,
    // which (being awaited before runApp) blanked the whole app on launch.
    const AndroidInitializationSettings android =
        AndroidInitializationSettings('@mipmap/launcher_icon');
    // We prompt explicitly later (after pairing), not at plugin init.
    const DarwinInitializationSettings darwin = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    await _plugin.initialize(
      const InitializationSettings(android: android, iOS: darwin),
    );
    final androidImpl = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await androidImpl?.createNotificationChannel(_deviceChannel);
    await androidImpl?.createNotificationChannel(_insightsChannel);
    _inited = true;
  }

  /// Request notification permission once (iOS always; Android 13+). Safe to call
  /// repeatedly — the result is cached. Returns whether notifications are allowed.
  Future<bool> ensurePermission() async {
    await init();
    if (_granted != null) return _granted!;
    bool granted = true;
    final ios = _plugin.resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin>();
    if (ios != null) {
      granted =
          await ios.requestPermissions(alert: true, badge: true, sound: true) ??
              false;
    }
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (android != null) {
      granted = await android.requestNotificationsPermission() ?? false;
    }
    _granted = granted;
    return granted;
  }

  /// Present (or replace) a device-alert notification. Same id replaces, so we
  /// never stack duplicate low-battery alerts. Never throws into the caller.
  Future<void> showDevice({
    required int id,
    required String title,
    required String body,
  }) async {
    try {
      final ok = await ensurePermission();
      if (!ok) return;
      await _plugin.show(
        id,
        title,
        body,
        NotificationDetails(
          android: AndroidNotificationDetails(
            _deviceChannel.id,
            _deviceChannel.name,
            channelDescription: _deviceChannel.description,
            importance: Importance.high,
            priority: Priority.high,
            icon: '@mipmap/ic_launcher',
          ),
          iOS: const DarwinNotificationDetails(),
        ),
      );
    } catch (_) {/* notifications are best-effort — never break the app */}
  }

  /// Present a locally-generated INSIGHT notification (recovery ready, wind-down,
  /// weekly recap). Lives on its own channel + id range. Never throws.
  Future<void> showInsight({
    required int id,
    required String title,
    required String body,
  }) async {
    try {
      final ok = await ensurePermission();
      if (!ok) return;
      await _plugin.show(
        id,
        title,
        body,
        NotificationDetails(
          android: AndroidNotificationDetails(
            _insightsChannel.id,
            _insightsChannel.name,
            channelDescription: _insightsChannel.description,
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
            icon: '@mipmap/ic_launcher',
          ),
          iOS: const DarwinNotificationDetails(),
        ),
      );
    } catch (_) {/* best-effort */}
  }

  Future<void> cancel(int id) async {
    try {
      await _plugin.cancel(id);
    } catch (_) {}
  }
}
