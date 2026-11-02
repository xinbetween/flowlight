#!/usr/bin/env swift
// Prints the window number of Flowlight's main window, optionally restricted to one exact process ID.
import AppKit
let requestedPID = CommandLine.arguments.dropFirst().first.flatMap(Int.init)
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let match = windows.first { info in
    let ownsWindow = requestedPID.map { (info[kCGWindowOwnerPID as String] as? Int) == $0 }
        ?? ((info[kCGWindowOwnerName as String] as? String) == "Flowlight")
    return ownsWindow
        && ((info[kCGWindowBounds as String] as? [String: Any])?["Height"] as? Double ?? 0) > 400
}
if let number = match?[kCGWindowNumber as String] as? Int { print(number) } else { exit(1) }
