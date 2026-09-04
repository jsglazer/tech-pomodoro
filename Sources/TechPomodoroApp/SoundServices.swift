import AppKit
import TechPomodoroCore

/// Plays the completion ding through `NSSound`.
final class SystemSoundPlayer: SoundPlaying, @unchecked Sendable {
    func play(named name: String) {
        // A name that no longer resolves must not silence the alert entirely.
        let sound = NSSound(named: name) ?? NSSound(named: SystemSoundCatalog.fallbackName)
        sound?.play()
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
