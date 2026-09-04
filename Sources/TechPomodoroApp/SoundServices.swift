import AppKit
import TechPomodoroCore

/// Plays the completion ding through `NSSound`, optionally several times in a row.
@MainActor
final class SystemSoundPlayer: SoundPlaying {
    private var pending: [DispatchWorkItem] = []

    nonisolated func play(named name: String, times: Int) {
        MainActor.assumeIsolated {
            // A new alert supersedes repeats still queued from the previous one.
            pending.forEach { $0.cancel() }
            pending.removeAll()

            // A name that no longer resolves must not silence the alert entirely.
            guard let sound = NSSound(named: name) ?? NSSound(named: SystemSoundCatalog.fallbackName) else { return }
            sound.play()

            // Space the repeats by the sound's own length where AppKit reports it, so a long chime
            // does not overlap itself.
            let gap = max(0.45, sound.duration + 0.1)
            for repetition in 1..<max(1, times) {
                let item = DispatchWorkItem {
                    (NSSound(named: name) ?? NSSound(named: SystemSoundCatalog.fallbackName))?.play()
                }
                pending.append(item)
                DispatchQueue.main.asyncAfter(deadline: .now() + gap * Double(repetition), execute: item)
            }
        }
    }
}

/// The sounds this machine can actually play, read from the system sound directories at launch
/// rather than hardcoded — the shipped set changes between macOS releases.
struct SystemSoundCatalog: SoundCatalogProviding {
    static let fallbackName = "Glass"

    let availableSoundNames: [String]

    init(fileManager: FileManager = .default) {
        let directories = [
            "/System/Library/Sounds",
            "/Library/Sounds",
            (NSHomeDirectory() as NSString).appendingPathComponent("Library/Sounds")
        ]

        var names: Set<String> = []
        for directory in directories {
            let contents = (try? fileManager.contentsOfDirectory(atPath: directory)) ?? []
            for file in contents {
                let name = (file as NSString).deletingPathExtension
                // Only offer names AppKit will actually resolve.
                if !name.isEmpty, NSSound(named: name) != nil {
                    names.insert(name)
                }
            }
        }

        if names.isEmpty {
            names.insert(Self.fallbackName)
        }
        availableSoundNames = names.sorted()
    }

    /// The stored name if it still resolves, otherwise the fallback — the caller surfaces the swap.
    func resolvedName(for stored: String) -> String {
        availableSoundNames.contains(stored) ? stored : (availableSoundNames.first ?? Self.fallbackName)
    }
}
