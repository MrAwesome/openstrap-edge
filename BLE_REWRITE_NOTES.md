# BLE transport rewrite — diagnosis, design, verification

Scope: replace the **transport / lifecycle** layer of the WHOOP 4.0 BLE client. The
byte/protocol layer (`package:openstrap_protocol` — framing, CRC, INIT, `buildCommand`,
`buildBatchAck`, `parseMetadata`, `decodeRecord`/`parseR24`, constants, `dangerousCmds`)
is correct and is **used as-is, never rewritten**.

Environment confirmed:
- Flutter 3.41.6, `flutter_blue_plus` resolves to **1.36.8** (constraint `^1.35.5`; the
  `connect()` here has NO `license:` param — that's the 2.x API). `connectionState`
  stream, `disconnectReason` getter, `isConnected`, `mtuNow`, `requestMtu`,
  `requestConnectionPriority`, `createBond`/`removeBond` all present.
- Baseline `flutter analyze` = 2 pre-existing info lints in `today_screen.dart` only.

---

## PHASE 1 — Diagnosed instability root-causes in the OLD engine

The old `lib/ble/ble_engine.dart` is a faithful 1:1 port of the Python `WhoopClient`
(`research_playground.py`) — so the **protocol sequence is right**. Every instability is
in how it manages the transport lifecycle. Specific findings:

1. **Connection state tracked by an ad-hoc string, not the FBP connection-state stream.**
   `state.connection` is a hand-set `String` (`'connecting'`/`'connected'`/`'syncing'`/
   `'disconnected'`). The only listener on `device.connectionState` (engine L222-226) just
   flips the string to `'disconnected'`; it ignores `disconnectReason` and never drives a
   reconnect. The real connection truth (the OS stream) and the app's belief diverge — the
   classic "UI says connected, link is dead" bug iOS hits after suspension. `isConnected`
   is derived from the STRING, so it lies.

2. **Overlapping / racing connect attempts — no single in-flight guard inside the engine.**
   `connect()` is fully re-entrant. `AppState` tries to gate it with `busy` / `_reconnecting`
   / `_keepAlive` bools, but those live in the *caller*. Three independent paths call into
   the engine concurrently: `openSession()`, `_reconnect()` (its own backoff loop), and the
   iOS-restore `runHeadlessSync()` (a *separate* `BleEngine` instance). Nothing in the engine
   prevents two `device.connect()` / `discoverServices()` / `_subscribe()` sequences running
   at once on the same peripheral → duplicate subscriptions, duplicate heartbeat timers,
   half-initialised state. This is the #1 source of flaky connects.

3. **Subscription & timer leaks across reconnects.** `_subs` accumulates: `connect()` adds
   3 characteristic listeners + 1 connectionState listener every call, but they are only
   cancelled in `disconnect()`. A reconnect that doesn't route through `disconnect()` (the
   `_reconnect()` loop calls `connectToRemoteId` directly) **stacks** listeners — every old
   `onValueReceived` closure keeps feeding a now-stale reassembler and double-counts records /
   double-ACKs. `_heartbeat` is cancelled-then-recreated in `connect()` but never in the
   disconnect-driven `_setConn('disconnected')` path, so a dropped link leaves a zombie timer
   firing `LINK_VALID` writes into a dead characteristic. Zombie listeners = the "works first
   connect, degrades after a few reconnects" instability.

4. **The drain loop is a polling `while` with `Future.delayed(1s)` — not event-driven.**
   `runSync()` spins a 1-second poll watching `_syncRecords`/`_lastTs`/`_syncComplete`. It has
   no idea the link dropped (it only checks the wall clock + record counters), so a mid-drain
   disconnect runs the full idle/timeout budget before returning, and the stop conditions race
   the `_handleSyncMarker` callback that mutates the same fields from the notify thread.

5. **Reassembler reset only at connect start, shared mutable state.** `_asm` is reset in
   `connect()`, but because a leaked old listener (finding 3) can still call
   `_asm[role].feed()`, a stale chunk can land in a freshly-reset reassembler and corrupt the
   first real frame after reconnect.

6. **`_writeChain` is an unbounded then-chain with no link-state check.** Writes are
   serialized (good) but a write enqueued before a disconnect still fires against `_cmdTo!`
   after the link died — `_cmdTo` is never nulled on disconnect, so it throws (caught) or, worse,
   targets a stale characteristic on a fast reconnect. No guard that the device is actually
   connected at write time.

7. **No bounded backoff INSIDE the engine; jitter absent.** The only backoff lives in
   `AppState._reconnect()` (`(2*attempt).clamp(2,30)`), linear-ish, no jitter, and it's
   defeated by finding 2 (it can start a connect while `openSession`'s is still mid-flight).
   reference's lesson: backoff + a single-flight guard belong together, in the transport.

8. **iOS-restore path runs a *second* engine against the same band.** `runHeadlessSync()`
   builds its own `BleEngine`. The only thing stopping it fighting the foreground engine is
   the `IosBleRestore.foregroundActive` bool checked in `ios_ble_restore.dart` — a coarse,
   easily-stale guard. If it's wrong, two engines connect/subscribe/ACK the same peripheral.

9. **No `disconnectReason` handling / no distinction between intentional vs. dropped.** The
   engine can't tell a user-initiated `disconnect()` from a link timeout, so the caller's
   reconnect logic can't either — it reconnects after intentional teardowns unless the caller
   races a `_keepAlive=false` first.

### What was RIGHT and is preserved verbatim (protocol-correct):
- 5-packet INIT, one-at-a-time 120 ms apart (`initPackets`).
- 3-state sync markers: HISTORY_START ignore / HISTORY_END → flush-then-ACK(0x17)+keep going /
  HISTORY_COMPLETE → stop, don't ACK.
- **Raw-first**: flush/persist the batch BEFORE writing the ACK.
- Byte-exact 8-byte token ACK via `buildBatchAck`.
- **write-WITH-response** for commands (triggers bonding; WoR drops the bond → silent ACK loss).
- SEQ discipline: live cmds high range (0xA0+), sync ACKs low (5+, continuing INIT 0..4).
- SET_CLOCK on connect (fresh-band RTC unset).
- `dangerousCmds` guard (0x19/0x1D/0x9A refused).
- Service-filtered scan, stop-early-on-match, never rapid start/stop.
- Live-edge + idle stop conditions for the drain.

---

## PHASE 2 — New design

A single explicit **connection state machine** owns one peripheral at a time. The FBP
**`connectionState` stream is the source of truth**; the engine never sets "connected" by hand.

### States (`BleConnState`)
`idle → scanning → connecting → discovering → subscribing → settingUp → ready
→ syncing → live`, with `reconnecting` and `error` as cross-cutting transitions. A single
`_phase` plus the FBP stream drives everything. `DeviceState.connection` (the legacy string
the UI reads) is derived from `_phase` so the public surface is unchanged.

### Single-flight guard (kills findings 2 & 7)
`_opLock` — a `Future` mutex around the whole connect→discover→subscribe→setup sequence and
around disconnect. `connect()` / `reconnectByRemoteId()` are **idempotent**: if an op is in
flight or we're already connected to the target, they return the in-flight result instead of
starting a second attempt. There is never more than one live `device.connect()`.

### Lifecycle resource tracking (kills findings 3, 5, 6)
A per-connection `_Session` object holds the device, characteristics, the three reassemblers,
ALL stream subscriptions, and the heartbeat timer. Teardown cancels every subscription + timer
and **nulls** the characteristics and device in one place, called on BOTH intentional disconnect
AND the connectionState→disconnected event. New connection = new `_Session`; no state bleeds
across reconnects. Writes check `_session?.connected` before touching a characteristic.

### Connection-state stream as truth (kills findings 1, 9)
We listen to `device.connectionState`. On `disconnected` we read `disconnectReason`, tear the
session down, and — if it was NOT an intentional disconnect and a session is wanted — hand off
to the reconnect controller. `isConnected` is derived from the live stream's last value, not a
bool we set.

### Reconnection: bounded exponential backoff + jitter, single-flight (finding 7)
`ReconnectPolicy` (pure, unit-tested): delay = `min(cap, base * 2^(attempt-1))` plus
`±jitter` randomization, capped (base 2s, cap 30s). The reconnect loop respects the same
`_opLock`, checks a `_wantConnection` flag each iteration, and **cannot** overlap a foreground
connect. Mirrors reference's `didFailToConnect` capped backoff (`min(60, 3*2^(n-1))`) and its
single auto-rescan scheduler.

### Drain controller: event-driven, raw-first, link-aware (finding 4)
`_DrainController` is driven by the metadata-marker callback, not a busy-poll. It exposes a
`Future<SyncReport>` that completes on HISTORY_COMPLETE, live-edge catch-up, idle watchdog, OR
link drop (so a mid-drain disconnect returns immediately instead of waiting the full budget).
An idle `Timer` (re-armed only on genuine offload frames, like reference's `armBackfillTimeout`)
and a live-edge check (newest record within 15 s of now) provide the non-COMPLETE exits. ACK
path is unchanged byte-for-byte: flush buffered raws → build `buildBatchAck(seq, token)` →
write-with-response → keep listening.

### Drain-completion signal preserved (DerivationEngine dependency)
`runSync()` still returns a `SyncReport(records, batches, complete)` and completes only after
the final `_flushDrain()`. `AppState._afterDrain(...)` fires off that completion exactly as
before — **the hook the DerivationEngine depends on is untouched.**

### iOS restoration = recovery-only (finding 8)
`ios_ble_restore.dart` keeps its `foregroundActive` guard. The headless engine instance still
exists, but now both engines share the single-flight discipline within their own instance, and
the design note documents that the `foregroundActive`/`setOwnsBand` handshake is the only
cross-instance coordination (unchanged contract; flagged as on-device-verify below). Restoration
reattaches to a restored peripheral cleanly via the same connect path.

### Preserved public surface (so `AppState` / `background_sync` compile unchanged)
`BleEngine({onRecord, onState, log, onEvent, onRecordsBatch})`, fields `state`,
`sinceLastRx`, `isConnected`; methods `scan()`, `connect(device)`, `connectToRemoteId(id)`,
`runSync({timeout})`, `enableLiveStreams()`, `disableLiveStreams()`, `setClock()`,
`setAlarm()`, `getAlarm()`, `disableAlarm()`, `getStrapName()`, `setStrapName()`,
`getBattery()`, `getHello()`, `buzz()`, `disconnect()`; typedefs `SampleSink`, `StateSink`,
`LogSink`, `EventSink`, `BatchSink`; class `SyncReport`. **No caller changes required.**

---

## PHASE 4 — Hardware verification checklist (REQUIRES a physical WHOOP 4.0 + device build)

BLE is empirical; none of the below is validated without hardware. This reimplementation
**compiles, analyzes clean, and passes the pure-logic unit tests** — that is the only claim made.

1. **Cold pair (Android):** force-quit official WHOOP app → pair in-app → bond dialog →
   INIT → drain completes → live HR appears. Confirm bonding via `createBond` succeeds.
2. **Cold pair (iOS):** first write-with-response triggers the system pairing prompt; accept;
   drain + live follow.
3. **Walk-away reconnect:** connect, walk out of range (link drops), walk back → engine
   reconnects on bounded backoff (watch logs: delays ~2,4,8,16,30s ±jitter), drains the
   offline backlog, resumes live. Confirm NO overlapping connect attempts in the log.
4. **Background drain (iOS):** background the app with a live link → confirm capture continues
   (notifications keep arriving) → kill the app → confirm CoreBluetooth relaunch via restore →
   headless drain runs once → re-arms. Confirm the restore path does NOT fire while
   `foregroundActive`.
5. **Background service (Android):** background with Edge Tracking service up → live drain
   continues → no zombie reconnect storms.
6. **ACK loop sanity (Groundhog-Day check):** during a large drain, confirm each HISTORY_END
   is ACKed exactly once with a byte-exact token and the cursor advances (records strictly
   increase, no batch is re-served forever). Pull the USB/log trace and diff the ACK frames.
7. **No zombie listeners after repeated connect/disconnect:** connect/disconnect 10× → confirm
   record counts don't double-count, only ONE heartbeat fires per 10 s, and memory/listener
   count is stable (no growth). This is the core regression the rewrite targets.
8. **Stale-link recovery (iOS resume):** background long enough that GATT notifications die
   silently, resume → `sinceLastRx` > 30 s path tears down + reconnects cleanly (re-subscribes).
9. **Intentional disconnect does NOT reconnect:** sign out / unpair → engine disconnects and
   stays down (no auto-reconnect storm).
10. **dangerousCmds never sent:** scan the on-device command log; confirm 0x19/0x1D/0x9A/0x6C
    never appear.

### Parts most likely to need on-device tuning (honest list)
- Backoff base/cap/jitter constants (2s/30s) — tune to real radio behaviour.
- Idle-watchdog (8s) and live-edge window (15s) for the drain stop conditions — firmware-/
  flash-rate-dependent; reference uses a more generous 60s idle for its raw-flood firmware.
- The iOS stale-link `sinceLastRx` 30s threshold (kept from old code) — empirical.
- Whether `requestConnectionPriority(high)` + `requestMtu(247)` ordering needs a small delay
  on some Android stacks before service discovery.
- The cross-instance foreground/restore handshake (`foregroundActive`) — the one piece NOT
  hardened to a stream; verify two engines never connect the same peripheral.
- write-with-response vs without on the cmd characteristic across firmware revisions (kept
  with-response per verified note; re-confirm on the user's band).
