import Foundation

/// Line-based three-way merge, the same idea as `git merge-file`: changes from both sides are
/// combined when they touch different parts of the note. Returns `nil` when both sides changed
/// the same lines differently, which the caller treats as a conflict.
enum TextMerge {
    private struct Hunk {
        /// Lines of the base replaced by this hunk (empty for pure insertions).
        var baseRange: Range<Int>
        var lines: [String]
    }

    static func merge(base: String, local: String, remote: String) -> String? {
        if local == remote { return local }
        if local == base { return remote }
        if remote == base { return local }

        let baseLines = base.components(separatedBy: "\n")
        let localHunks = hunks(from: baseLines, to: local.components(separatedBy: "\n"))
        let remoteHunks = hunks(from: baseLines, to: remote.components(separatedBy: "\n"))

        var result: [String] = []
        var cursor = 0
        var l = 0, r = 0
        while l < localHunks.count || r < remoteHunks.count {
            let next: Hunk
            if l < localHunks.count, r < remoteHunks.count {
                let a = localHunks[l], b = remoteHunks[r]
                if overlaps(a.baseRange, b.baseRange) {
                    // Identical changes on both sides are fine; anything else is a real conflict.
                    guard a.baseRange == b.baseRange, a.lines == b.lines else { return nil }
                    next = a; l += 1; r += 1
                } else if a.baseRange.lowerBound < b.baseRange.lowerBound
                            || (a.baseRange.lowerBound == b.baseRange.lowerBound && a.baseRange.isEmpty) {
                    next = a; l += 1
                } else {
                    next = b; r += 1
                }
            } else if l < localHunks.count {
                next = localHunks[l]; l += 1
            } else {
                next = remoteHunks[r]; r += 1
            }
            result += baseLines[cursor..<next.baseRange.lowerBound]
            result += next.lines
            cursor = next.baseRange.upperBound
        }
        result += baseLines[cursor...]
        return result.joined(separator: "\n")
    }

    /// Whether two hunks change the same lines. Unlike git, edits on adjacent lines merge cleanly,
    /// which suits notes where neighbouring lines are often edited independently.
    private static func overlaps(_ a: Range<Int>, _ b: Range<Int>) -> Bool {
        switch (a.isEmpty, b.isEmpty) {
        case (true, true): a.lowerBound == b.lowerBound
        case (true, false): b.lowerBound < a.lowerBound && a.lowerBound < b.upperBound
        case (false, true): a.lowerBound < b.lowerBound && b.lowerBound < a.upperBound
        case (false, false): a.lowerBound < b.upperBound && b.lowerBound < a.upperBound
        }
    }

    private static func hunks(from base: [String], to other: [String]) -> [Hunk] {
        let difference = other.difference(from: base)
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in difference {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var hunks: [Hunk] = []
        var i = 0, j = 0
        while i < base.count || j < other.count {
            if removed.contains(i) || inserted.contains(j) {
                let startI = i, startJ = j
                while removed.contains(i) { i += 1 }
                while inserted.contains(j) { j += 1 }
                hunks.append(Hunk(baseRange: startI..<i, lines: Array(other[startJ..<j])))
            } else {
                i += 1; j += 1
            }
        }
        return hunks
    }
}
