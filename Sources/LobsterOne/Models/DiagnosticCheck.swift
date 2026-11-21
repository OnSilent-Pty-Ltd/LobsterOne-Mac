import Foundation

enum CheckStatus: Equatable {
    case pending
    case running
    case passed(String)
    case warning(String)
    case failed(String)
    case skipped(String)
    case fixing
}

struct DiagnosticCheck: Identifiable {
    let id: String
    let title: String
    var status: CheckStatus = .pending
    /// Whether this check has an automated fix. Diagnose-only checks
    /// (e.g. telemetry delivery) set this false so no Fix button is shown.
    var fixable: Bool = true
    var canFix: Bool {
        guard fixable else { return false }
        switch status {
        case .warning, .failed: return true
        default: return false
        }
    }

    var sfSymbol: String {
        switch status {
        case .pending: return "circle"
        case .running, .fixing: return "arrow.trianglehead.2.clockwise"
        case .passed: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.circle.fill"
        case .skipped: return "minus.circle.fill"
        }
    }

    var statusColor: String {
        switch status {
        case .passed: return "green"
        case .warning: return "yellow"
        case .failed: return "red"
        case .skipped: return "gray"
        default: return "secondary"
        }
    }

    var detail: String {
        switch status {
        case .pending: return "Not checked yet"
        case .running: return "Checking..."
        case .passed(let msg), .warning(let msg), .failed(let msg), .skipped(let msg): return msg
        case .fixing: return "Fixing..."
        }
    }

    static func initial() -> [DiagnosticCheck] {
        [
            DiagnosticCheck(id: "shell", title: "Shell Environment"),
            DiagnosticCheck(id: "claude-code", title: "Claude Code Config"),
            DiagnosticCheck(id: "codex", title: "Codex Config"),
            DiagnosticCheck(id: "keys", title: "API Key Validation"),
            DiagnosticCheck(id: "endpoints", title: "Endpoint Consistency"),
            DiagnosticCheck(id: "telemetry", title: "Telemetry Delivery", fixable: false),
        ]
    }
}
