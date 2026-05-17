/// Public alias for the current SwiftData chat session model.
///
/// SchemaV8 (#1301) adds `isPinned: Bool` and `pinnedAt: Date?` columns. The
/// alias points at the V8 model so existing call sites keep compiling while
/// gaining the new pinning fields.
public typealias ChatSession = ManifoldSchemaV8.ChatSession
