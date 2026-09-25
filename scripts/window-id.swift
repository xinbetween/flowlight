#!/usr/bin/env swift
// Prints the window number of Flowlight's main window, so `screencapture -l` can take it without a mouse.
import AppKit
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
let match = windows.first { info in
    (info[kCGWindowOwnerName as String] as? String) == "Flowlight"
        && ((info[kCGWindowBounds as String] as? [String: Any])?["Height"] as? Double ?? 0) > 400
}
if let number = match?[kCGWindowNumber as String] as? Int { print(number) } else { exit(1) }
