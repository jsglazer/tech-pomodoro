# Mirroring the Mac timer on the iPhone

While a timer runs on a Mac, the iPhone's Lock Screen and Dynamic Island Live Activity, and the iPhone app's Timer tab, show that Mac's phase, countdown, progress line and upcoming boundaries. This works even when the iPhone app is not running. It is display only: the iPhone cannot control the Mac.

## How it works

- **Transport.** The Mac sends Live Activity pushes to APNs directly over HTTP/2, using token-based auth (a .p8 key). A Mac start sends one push-to-start to each iPhone, and that push subscribes the new activity to an APNs **broadcast channel**. Every later change (pause, resume, skip, phase boundary, stop, or a settings change that moves the schedule) is a single broadcast on that channel. The countdown runs on the phone from `phaseStartedAt`/`phaseEndsAt`, so the Mac never pushes per second.
- **Hand-off.** Records of type `MirrorRecord` sit in the existing CloudKit zone `Pomodoro`: `phone-<id>` (the iPhone's push-to-start token, its APNs environment and its switch), `mac-<id>` (each Mac's timer as it last changed) and `channel-<env>` (the broadcast channel id, plus what was last pushed so no Mac repeats a push). The Mac writes its own timer and reads all of them just before it pushes.
- **Conflict rule.** While a Mac timer is active it wins, and the iPhone's own timer keeps running underneath. If several Macs run timers, the one that changed most recently wins. A running Mac that misses its phase end by more than 5 minutes, or a Mac paused for more than 12 hours, drops out. When no Mac is active, the iPhone goes back to its own timer.
- **Rules in the core.** `Sources/TechPomodoroCore/Mirror.swift` holds the content builder, `MirrorArbiter` (which timer wins), `MirrorPushPlanner` (what to push, with no repeats) and `APNsPayload`. `Tests/TechPomodoroCoreTests/MirrorTests.swift` tests them headlessly.

## One-time setup

1. **APNs key.** At developer.apple.com, go to Certificates, Identifiers & Profiles → Keys → **+**, tick **Apple Push Notifications service (APNs)**, choose Sandbox & Production, then register and download `AuthKey_XXXXXXXXXX.p8` (you can only download it once).
2. **Broadcast capability.** In Identifiers → `com.jsglazer.tech-pomodoro.ios` → Push Notifications, tick **Broadcast Capability** and save. Without it, creating a channel fails with an APNs error that the Mac shows in its status line.
3. **CloudKit schema.** Import `CloudKit/schema.ckdb` into Development, then **Deploy Schema Changes…** to Production (see `CloudKit/README.md`).
4. **iPhone.** Install with `./MakeiOSDeploy.sh` (iOS 18.0 or later). Open the app once with Settings → **Show Mac timer** on, so it publishes its push-to-start token.
5. **Mac.** In the popover's Settings tab, turn on **Mirror timer to iPhone**, click **Import .p8…** and pick the key. The Key ID comes from the file name and the Team ID from the app's own signature; both can be edited. The key lives in the login Keychain and is never written to the repo or to the app's files.

The status line under the switch reads `Mirroring to iPhone · last push 09:41` once a push has gone out. If something fails, it shows the APNs or CloudKit error in the warning colour.

## Manual QA checklist

- [ ] Mac start, iPhone locked: the Live Activity appears on the Lock Screen within a few seconds, showing the Mac name in place of the buttons. The countdown matches the Mac.
- [ ] Mac pause: the activity shows `Paused — Work` with a frozen readout. Resume: it counts down again from the same point.
- [ ] Mac skip: the activity moves to the next phase right away.
- [ ] Phase boundary on the Mac: the activity moves on at the boundary without the iPhone app being opened.
- [ ] Mac stop: the activity leaves the Lock Screen.
- [ ] iPhone app force-quit (swiped away in the app switcher), then a Mac start, pause and stop: all of them still reach the Lock Screen.
- [ ] iPhone rebooted, then unlocked once: a Mac start still creates the activity.
- [ ] iPhone app open during a Mac timer: the Timer tab shows the Mac's timer with no Start/Pause/Skip/Stop, and returns to the iPhone's own timer when the Mac stops.
- [ ] iPhone timer running, then the Mac starts: the iPhone's own Live Activity gives way to the Mac's once the app is next opened, and comes back after the Mac stops and the app is opened again.
- [ ] Swipe the mirrored activity away: the next Mac change brings it back.
- [ ] Mac quit while running: the activity ends (or, with a second Mac running, switches to that Mac).
- [ ] **Show Mac timer** off on the iPhone: no mirrored activity appears, and the Timer tab shows only the iPhone's timer.
- [ ] **Mirror timer to iPhone** off on the Mac: the activity ends and nothing more is pushed.
