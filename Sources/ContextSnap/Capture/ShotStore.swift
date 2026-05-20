import Foundation

enum ShotStore {
    static var directory: URL {
        SettingsStore.shared.saveDirectory
    }

    static func ensureDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    static func newURL() -> URL {
        ensureDirectory()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let stamp = formatter.string(from: Date())
        return directory.appendingPathComponent("clip-\(stamp).png")
    }
}
