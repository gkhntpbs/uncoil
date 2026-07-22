import Foundation

// MARK: - Project

struct Project: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var rootPath: String
    var createdAt: Date

    var rootURL: URL { URL(fileURLWithPath: rootPath) }

    init(id: UUID = UUID(), name: String, rootPath: String, createdAt: Date = .now) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.createdAt = createdAt
    }
}

// MARK: - Agent session

enum AgentSessionStatus: String, Codable {
    case idle
    case running
    case waitingForPermission
    case waitingForInput
    case completed
    case terminated

    var label: String {
        switch self {
        case .idle: "Boşta"
        case .running: "Çalışıyor"
        case .waitingForPermission: "İzin bekliyor"
        case .waitingForInput: "Yanıt bekliyor"
        case .completed: "Tamamlandı"
        case .terminated: "Kapandı"
        }
    }

    /// Higher value = more urgent in sidebar/menu ordering.
    var attentionPriority: Int {
        switch self {
        case .waitingForPermission: 5
        case .waitingForInput: 4
        case .running: 3
        case .completed: 2
        case .idle: 1
        case .terminated: 0
        }
    }
}

/// One terminal-backed agent session inside a project.
final class AgentSession: ObservableObject, Identifiable {
    let id: UUID
    let projectID: UUID
    let title: String
    let startedAt: Date

    @Published var status: AgentSessionStatus = .idle
    @Published var statusDetail: String?
    @Published var providerSessionID: String?

    init(id: UUID = UUID(), projectID: UUID, title: String, startedAt: Date = .now) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.startedAt = startedAt
    }
}
