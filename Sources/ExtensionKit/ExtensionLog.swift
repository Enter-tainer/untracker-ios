//
//  ExtensionLog.swift
//  ExtensionKit
//
//  Tiny on-device log for the two extensions. Writes to `NSLog` (visible in Xcode's console)
//  and appends a line to the shared App Group container, so a build installed over the air
//  can still be diagnosed by pulling the container — no debugger needed (Ad Hoc installs have
//  get-task-allow=false).
//

import Foundation

enum ExtensionLog {
    private static let fileName = "extension-log.txt"

    static func line(_ message: String) {
        NSLog("[UntrackerExt] %@", message)
        guard let url = SharedStore.appGroupContainerURL?.appendingPathComponent(fileName) else {
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
