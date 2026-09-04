# tech-pomodoro

A menu-bar-only Pomodoro timer for macOS with a multi-tier schedule: work/rest reps build a cycle, cycles build a session, and each level gets its own break.

## Why

Most Pomodoro apps stop at "work, rest, long break". tech-pomodoro adds the level above that — a session of cycles with its own long rest at the end, optionally repeating forever — and puts the countdown itself in the menu bar, colour-shifting as work time runs out.

## Features

- **Multi-tier schedule.** Work and rest alternate for the reps of a cycle; the cycle closes with a long break; a session of cycles closes with a session rest. Every duration and count is configurable, and the session can repeat indefinitely.
- **The countdown is the control.** Click the numbers in the popover to pause or resume; Start (which becomes Stop once running) and Pause sit beneath them.
- **Menu bar as a countdown.** Show minutes remaining or a clock icon, optionally on a filled background. During Work the minutes turn yellow at a warning threshold and red at an alert threshold — both configurable, either one disabled by setting it to 0. The rest phases get their own colour (green by default), and the ordinary countdown takes a colour of your choosing.
- **Alerts.** A system-sound ding and a menu bar flash at every interval, cycle, and session boundary — each independently switchable, and each repeatable up to ten times. Sounds are read from this Mac's sound folders, so the picker never offers something that will not play.
- **Sleep-aware.** By default the timer keeps counting against the wall clock through a system sleep and fast-forwards on wake to exactly the phase the clock implies, with a single catch-up ding rather than a backlog. It can pause on sleep instead.
- **Hover readout.** Hovering the menu bar item shows the phase and the exact time left — `Rest 03:12` — in a panel at roughly twice tooltip size, tinted to match the menu bar.
- **Analytics.** Sessions and cycles completed and total work time for Today, the last 3 days, and the last 5 days, as calendar days in your timezone. Hover the panel to refresh it; the numbers are visible either way.
- **Export.** The full interval history as CSV or JSON.
- **Launch at login**, via `SMAppService`.

## Install

Requires macOS 14 or later.

```sh
git clone https://github.com/jsglazer/tech-pomodoro.git
cd tech-pomodoro
xcodegen generate
xcodebuild -project TechPomodoro.xcodeproj -scheme TechPomodoro -configuration Release build
```

Or download the notarized DMG from [Releases](https://github.com/jsglazer/tech-pomodoro/releases) and drag the app into `/Applications`. To build a signed DMG yourself, run `Scripts/make-dmg.sh`.

Then copy the built `TechPomodoro.app` into `/Applications`. Launch at login only works from a properly registered bundle, so run it from `/Applications` rather than from the build directory.

## Architecture

The timer engine is a pure Swift state machine with no AppKit or SwiftUI anywhere in it:

- `Sources/TechPomodoroCore` — the reducer, the analytics aggregator, the menu bar formatting model, and the stores. No UI imports, no reads of the system clock, no hardcoded paths. Every instant arrives as a parameter and every dependency is injected.
- `Sources/TechPomodoroApp` — the OS shell: the status item, the SwiftUI popover, `NSSound`, `SMAppService`, and the `NSWorkspace` sleep/wake observers. One 1-second runloop timer drives display refresh only; it never advances the timer, which is always derived from an absolute end timestamp against the injected clock.

That split is what makes the interesting parts testable: `swift test` covers the multi-tier transitions, sleep/wake fast-forward, pause/resume/stop edge cases, threshold colours, rolling analytics windows, pruning, and the persistence and export roundtrips.

```sh
swift test
```

## Credits

Layout and settings structure were inspired by [TomatoBar](https://github.com/ivoronin/TomatoBar) by Ivan Voronin. No code from it is used here — tech-pomodoro is a clean build.

## License

MIT — see [LICENSE](LICENSE).
