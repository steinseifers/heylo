import Foundation

/// Fork-specific identity and switches, kept in one place so merges from upstream stay small.
enum Brand {
    /// User-visible product name (window titles, menus).
    static let name = "Stein's Mail"
    /// The upstream MCP server is switched off in this fork.
    static let mcpAvailable = false
}
