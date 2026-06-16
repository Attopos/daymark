import Foundation

/// Keeps the Development and Production data sets isolated so that switching
/// between a Debug build (CloudKit development environment) and a TestFlight /
/// App Store build (production environment) on the same device does not cause
/// each one to re-sync the other environment's data.
///
/// Debug builds get a separate on-disk store and separately named CloudKit
/// zones; Production builds keep the original store location and zone names so
/// existing users' data is untouched.
enum SyncEnvironment {
    /// Suffix appended to every custom CloudKit zone name in Debug builds.
    static let zoneSuffix: String = {
        #if DEBUG
        "-Dev"
        #else
        ""
        #endif
    }()

    /// Applies the environment suffix to a base zone name.
    static func zoneName(_ base: String) -> String {
        base + zoneSuffix
    }

    /// Dedicated on-disk SwiftData store URL for Debug builds. Returns `nil` for
    /// Production builds so SwiftData keeps using its default store location and
    /// existing users' data is preserved across updates.
    static var debugStoreURL: URL? {
        #if DEBUG
        URL.applicationSupportDirectory.appending(path: "Daymark-Dev.store")
        #else
        nil
        #endif
    }

    /// Dedicated, local-only store URL for the anonymous (no-account) scope so
    /// its data never mixes with the signed-in / iCloud data. Scoped per build
    /// environment so Debug and Production anonymous stores stay separate too.
    static var anonymousStoreURL: URL {
        #if DEBUG
        let name = "Daymark-Dev-Anonymous.store"
        #else
        let name = "Daymark-Anonymous.store"
        #endif
        return URL.applicationSupportDirectory.appending(path: name)
    }
}
