import LiveWallpaperCore
import SwiftUI

enum AgentPresentation {
    static func phase(_ phase: MonitorAgentPhase) -> String {
        let key: String.LocalizationValue = switch phase {
        case .responding: "Generating response"
        case .executing: "Executing tools"
        case .waitingForInput: "Waiting for answer"
        case .waitingForApproval: "Waiting for approval"
        case .waitingForAgents: "Waiting for agents"
        case .completed: "Turn completed"
        case .interrupted: "Interrupted"
        case .failed: "Failed"
        case .unknown: "Status unknown"
        }
        return String(localized: key, bundle: .appLanguage)
    }

    static func symbol(_ phase: MonitorAgentPhase) -> String {
        switch phase {
        case .responding: "text.bubble"
        case .executing: "terminal"
        case .waitingForInput: "questionmark.bubble"
        case .waitingForApproval: "hand.raised"
        case .waitingForAgents: "person.2"
        case .completed: "checkmark.circle"
        case .interrupted: "pause.circle"
        case .failed: "exclamationmark.circle"
        case .unknown: "questionmark.circle"
        }
    }

    static func color(_ phase: MonitorAgentPhase) -> Color {
        switch phase {
        case .waitingForInput, .waitingForApproval, .failed: DesignTokens.Colors.Status.warning
        case .completed: DesignTokens.Colors.Status.active
        case .executing, .responding, .waitingForAgents: DesignTokens.Colors.accent
        case .interrupted, .unknown: DesignTokens.Colors.textSecondary
        }
    }

    static func toolOutcome(_ tool: MonitorAgentToolEvent) -> String {
        let key: String.LocalizationValue = tool.interrupted == true ? "Interrupted" : tool.completedAt == nil ? "In progress"
            : (tool.ok == true ? "Succeeded" : (tool.ok == false ? "Failed" : "Result received"))
        return String(localized: key, bundle: .appLanguage)
    }
}
