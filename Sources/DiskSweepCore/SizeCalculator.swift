import Foundation

public enum SizeCalculator {
    /// Bytes actually allocated on disk for a file or a whole directory tree.
    /// Symlinks are never followed.
    public static func allocatedSize(of url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return 0 }
        if values.isSymbolicLink == true { return 0 }
        if values.isDirectory != true { return Int64(values.totalFileAllocatedSize ?? 0) }

        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }
        ) else { return 0 }

        var total: Int64 = 0
        while let file = enumerator.nextObject() as? URL {
            if Task.isCancelled { break }
            guard let v = try? file.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            total += Int64(v.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Runs `transform` over `inputs` with at most `limit` running at once,
    /// keeping the result order.
    public static func concurrentMap<T: Sendable, R: Sendable>(
        _ inputs: [T], limit: Int = 8, _ transform: @escaping @Sendable (T) async -> R
    ) async -> [R] {
        var results = [R?](repeating: nil, count: inputs.count)
        await withTaskGroup(of: (Int, R).self) { group in
            var next = 0
            while next < min(limit, inputs.count) {
                let index = next
                group.addTask { (index, await transform(inputs[index])) }
                next += 1
            }
            while let (index, value) = await group.next() {
                results[index] = value
                if next < inputs.count {
                    let nextIndex = next
                    next += 1
                    group.addTask { (nextIndex, await transform(inputs[nextIndex])) }
                }
            }
        }
        return results.map { $0! }
    }

    /// Parses Docker CLI sizes such as "1.2GB (45%)", "512.3MB", "0B", "1.5kB".
    public static func parseDockerSize(_ text: String) -> Int64? {
        let token = text.split(separator: " ").first.map(String.init) ?? text
        let digits = token.prefix { $0.isNumber || $0 == "." }
        guard let number = Double(digits) else { return nil }
        let unit = token.dropFirst(digits.count).lowercased()
        let multiplier: Double
        switch unit {
        case "b", "": multiplier = 1
        case "kb": multiplier = 1_000
        case "mb": multiplier = 1_000_000
        case "gb": multiplier = 1_000_000_000
        case "tb": multiplier = 1_000_000_000_000
        case "kib": multiplier = 1_024
        case "mib": multiplier = 1_048_576
        case "gib": multiplier = 1_073_741_824
        case "tib": multiplier = 1_099_511_627_776
        default: return nil
        }
        return Int64((number * multiplier).rounded())
    }
}
