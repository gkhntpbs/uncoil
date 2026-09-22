import Foundation

enum UpdateChannel: String, CaseIterable, Identifiable {
    case stable
    case edge

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stable: "Stable"
        case .edge: "Edge"
        }
    }

    var feedURL: URL {
        switch self {
        case .stable: URL(string: "https://uncoil.gokhantopbas.com/appcast.xml")!
        case .edge: URL(string: "https://uncoil.gokhantopbas.com/appcast-edge.xml")!
        }
    }

    static func installed(in bundle: Bundle = .main) -> UpdateChannel {
        UpdateChannel(rawValue: bundle.object(forInfoDictionaryKey: "UncoilReleaseChannel") as? String ?? "") ?? .stable
    }
}

final class UpdateChannelPreference {
    static let key = "UncoilUpdateChannel"
    private let defaults: UserDefaults
    private(set) var channel: UpdateChannel

    init(defaults: UserDefaults) {
        self.defaults = defaults
        channel = UpdateChannel(rawValue: defaults.string(forKey: Self.key) ?? "") ?? .stable
    }

    @discardableResult
    func select(_ channel: UpdateChannel, sessionInProgress: Bool) -> Bool {
        guard !sessionInProgress, channel != self.channel else { return false }
        defaults.set(channel.rawValue, forKey: Self.key)
        self.channel = channel
        return true
    }
}
