import Foundation

struct ReleaseVersion: Comparable {
    private let components: [Int]

    init?(_ value: String) {
        var normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.first == "v" || normalized.first == "V" {
            normalized.removeFirst()
        }

        let parts = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return nil }

        var components: [Int] = []
        for part in parts {
            guard !part.isEmpty,
                  part.allSatisfy(\.isNumber),
                  let component = Int(part) else {
                return nil
            }
            components.append(component)
        }

        while components.count > 1 && components.last == 0 {
            components.removeLast()
        }
        self.components = components
    }

    static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        let componentCount = max(lhs.components.count, rhs.components.count)
        for index in 0..<componentCount {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }
}

enum AppArchitecture: String {
    case arm64
    case x86_64

    static var current: AppArchitecture {
#if arch(arm64)
        return .arm64
#elseif arch(x86_64)
        return .x86_64
#else
#error("PiWork updates support only arm64 and x86_64 macOS builds")
#endif
    }
}
