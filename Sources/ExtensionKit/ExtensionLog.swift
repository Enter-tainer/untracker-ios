//
//  ExtensionLog.swift
//  ExtensionKit
//
//  Tiny on-device log for the two extensions. Writes to `NSLog` (visible in Xcode's console)
//  and appends a line to the shared App Group container, so a build installed over the air
//  can still be diagnosed by pulling the container — no debugger needed (Ad Hoc installs have
//  get-task-allow=false).
//
//  The file lives under `Library/Logs/` on purpose: `xcrun devicectl device copy from`
//  only exposes an app group's `Library`, `Documents` and `tmp` directories, so a log at
//  the container root cannot be pulled off a physical device.
//

import Foundation

enum ExtensionLog {
    private static let directoryName = "Logs"
    private static let fileName = "extension-log.txt"

    private static var fileURL: URL? {
        guard let container = SharedStore.appGroupContainerURL else { return nil }
        let directory = container
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory.appendingPathComponent(fileName)
    }

    static func line(_ message: String) {
        NSLog("[UntrackerExt] %@", message)
        guard let url = fileURL else {
            return
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withTime, .withColonSeparatorInTime]
        let text = formatter.string(from: Date()) + " " + message + "\n"
        let data = Data(text.utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
