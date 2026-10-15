import Foundation

/// Converts a JSON number the model sent as a double into an Int without
/// trapping: values beyond Int's range saturate, NaN/infinity yield nil.
/// `Int(_: Double)` traps on anything out of range, and one malformed tool
/// call (e.g. `"limit": 1e20`) must not take the whole process down.
func clampedToolInt(_ value: Double) -> Int? {
    guard value.isFinite else { return nil }
    if value >= 9.2e18 { return Int.max }
    if value <= -9.2e18 { return Int.min }
    return Int(value)
}
