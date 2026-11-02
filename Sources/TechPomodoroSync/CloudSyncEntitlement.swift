import Foundation
#if os(macOS)
import Security
#endif

/// Whether this binary was signed with the iCloud container entitlement.
///
/// `CKContainer` traps when the entitlement is missing, and the Mac app is also built unsigned by
/// `swift build` and ad-hoc by the fallback DMG path — so on macOS the entitlement is checked before
/// CloudKit is touched at all, and sync simply reports itself unavailable. iOS builds always come
/// from Xcode with their entitlements, and iOS offers no public way to read them, so it is assumed.
enum CloudSyncEntitlement {
    static let isPresent: Bool = {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        let value = SecTaskCopyValueForEntitlement(
            task,
            "com.apple.developer.icloud-container-identifiers" as CFString,
            nil
        )
        guard let containers = value as? [String] else { return false }
        return containers.contains(CloudSync.containerIdentifier)
        #else
        return true
        #endif
    }()
}
