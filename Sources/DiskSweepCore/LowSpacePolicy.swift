public enum LowSpacePolicy {
    public static func shouldNotify(available: Int64, total: Int64, thresholdBytes: Int64, armed: Bool) -> Bool {
        armed && total > 0 && available >= 0 && thresholdBytes > 0 && available < thresholdBytes
    }

    public static func shouldRearm(available: Int64, total: Int64, thresholdBytes: Int64) -> Bool {
        total > 0 && available >= 0 && thresholdBytes > 0 &&
            Double(available) >= Double(thresholdBytes) * 1.1
    }
}
