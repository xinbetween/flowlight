#!/usr/bin/env swift
// Prints the window number—or, with --title, the title—of Flowlight's main window, optionally restricted to one
// exact process ID. Both screenshot identity checks come from Core Graphics, so Accessibility permission cannot make
// title lookup fail while capture still sees the window.
import AppKit
let arguments = Array(CommandLine.arguments.dropFirst())
let titleOnly = arguments.first == "--title"
let requestedPID = (titleOnly ? arguments.dropFirst().first : arguments.first).flatMap(Int.init)
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let match = windows.first { info in
    let ownsWindow = requestedPID.map { (info[kCGWindowOwnerPID as String] as? Int) == $0 }
        ?? ((info[kCGWindowOwnerName as String] as? String) == "Flowlight")
    return ownsWindow
        && ((info[kCGWindowBounds as String] as? [String: Any])?["Height"] as? Double ?? 0) > 400
}
if titleOnly {
    if let title = match?[kCGWindowName as String] as? String, !title.isEmpty { print(title) } else { exit(1) }
} else if let number = match?[kCGWindowNumber as String] as? Int {
    print(number)
} else {
    exit(1)
}
