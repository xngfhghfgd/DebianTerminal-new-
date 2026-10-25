import Foundation

/// 虚拟机生命周期状态机。
enum VMState: String, CaseIterable, Codable, Sendable {
    case stopped
    case starting
    case running
    case stopping
    case crashed

    var displayName: String {
        switch self {
        case .stopped:  return "Stopped"
        case .starting: return "Starting"
        case .running:  return "Running"
        case .stopping: return "Stopping"
        case .crashed:  return "Crashed"
        }
    }
}

/// JIT 检测状态。
enum JITStatus: String, Codable, Sendable {
    case unknown
    case available
    case unavailable

    var isAvailable: Bool { self == .available }
}
