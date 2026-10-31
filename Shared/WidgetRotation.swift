import Foundation

/// Pure, stable 3-hour rotation. Every album in the published library is eligible.
/// Shuffle order changes daily; within a day, eight slots use different albums
/// whenever at least eight are available. No external service or live Spotify
/// token is needed in the extension.
enum WidgetRotation {
    static func nextBoundary(after date: Date, calendar: Calendar = .current) -> Date {
        let currentHour = calendar.component(.hour, from: date)
        let targetHour = ((currentHour / 3) + 1) * 3
        if targetHour >= 24 {
            return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))
                ?? date.addingTimeInterval(10_800)
        }
        return calendar.date(bySettingHour: targetHour, minute: 0, second: 0, of: date,
                             matchingPolicy: .nextTime) ?? date.addingTimeInterval(10_800)
    }

    static func index(albumIDs: [String], at date: Date, seed: String,
                      calendar: Calendar = .current) -> Int? {
        guard !albumIDs.isEmpty else { return nil }
        if albumIDs.count == 1 { return 0 }
        let parts = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        let stamp = "\(seed)|\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
        var state: UInt64 = 14_695_981_039_346_656_037
        for byte in stamp.utf8 { state = (state ^ UInt64(byte)) &* 1_099_511_628_211 }
        // Fisher–Yates with a reproducible pseudo-random generator.
        var indexes = Array(albumIDs.indices)
        for end in stride(from: indexes.count - 1, through: 1, by: -1) {
            state ^= state >> 12
            state ^= state << 25
            state ^= state >> 27
            let random = state &* 2_685_821_657_736_338_717
            indexes.swapAt(end, Int(random % UInt64(end + 1)))
        }
        let slot = (parts.hour ?? 0) / 3
        return indexes[slot % indexes.count]
    }
}
