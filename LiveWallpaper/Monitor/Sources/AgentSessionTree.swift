import Foundation

struct AgentSessionTreeNode: Identifiable {
    var session: MonitorAgentSessionState
    var children: [AgentSessionTreeNode]?
    var id: String {
        session.id
    }

    /// Broken/missing parent links become roots; cycles cannot hide sessions or recurse forever.
    static func build(_ sessions: [MonitorAgentSessionState]) -> [Self] {
        var seen = Set<String>()
        let unique = sessions.filter { seen.insert($0.id).inserted }
        let ids = Set(unique.map(\.id))
        let roots = unique.filter { $0.parentSessionID == nil || !ids.contains($0.parentSessionID!) }
        var used = Set<String>()
        func node(_ session: MonitorAgentSessionState, depth: Int) -> Self? {
            guard depth < 16, used.insert(session.id).inserted else { return nil }
            let children = unique.filter { $0.parentSessionID == session.id }.compactMap { node($0, depth: depth + 1) }
            return Self(session: session, children: children.isEmpty ? nil : children)
        }
        var result = roots.compactMap { node($0, depth: 0) }
        for session in unique where !used.contains(session.id) {
            if let orphan = node(session, depth: 0) {
                result.append(orphan)
            }
        }
        return result
    }
}
