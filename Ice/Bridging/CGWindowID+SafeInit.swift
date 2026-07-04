//
//  CGWindowID+SafeInit.swift
//  Ice
//

import CoreGraphics

extension CGWindowID {
    /// Creates a window identifier from a raw `NSWindow.windowNumber`, returning
    /// `nil` for non-positive or out-of-range values instead of trapping.
    ///
    /// `CGWindowID` is a `UInt32`; `NSWindow.windowNumber` is an `Int`. The direct
    /// `CGWindowID(windowNumber)` conversion **traps** on negative or too-large
    /// values. On macOS 26 (Tahoe), status-item windows can report a negative
    /// `windowNumber`, which crashed the IceBar's origin calculation. This
    /// initializer fails gracefully instead.
    init?(safeWindowNumber windowNumber: Int) {
        guard windowNumber > 0, windowNumber <= Int(UInt32.max) else {
            return nil
        }
        self = CGWindowID(windowNumber)
    }
}
