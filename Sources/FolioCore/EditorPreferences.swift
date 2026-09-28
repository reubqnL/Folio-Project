public enum EditorPreferences {
    public static let defaultPointSize: Double = 15
    public static let allowedPointSizes: ClosedRange<Double> = 11...32

    /// UserDefaults is not a trusted source of valid numeric ranges.
    public static func clampedPointSize(_ value: Double) -> Double {
        guard value.isFinite else { return defaultPointSize }
        return min(allowedPointSizes.upperBound, max(allowedPointSizes.lowerBound, value))
    }
}
