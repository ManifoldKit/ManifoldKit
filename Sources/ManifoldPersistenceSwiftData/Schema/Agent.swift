/// The SwiftData persistence model for an agent persona. Renamed at the
/// module-public layer to ``PersistedAgent`` — originally to avoid shadowing
/// ``ManifoldInference/AgentDefinition`` (the value type that flows through
/// the runtime), which itself was renamed off the bare `Agent` name in the
/// wave-2 mechanical batch (N5) once the two-name pair proved confusing even
/// with module-qualification. The underlying `@Model` class remains
/// ``ManifoldSchemaV9/Agent`` so existing SwiftData stores stay valid — this
/// is a schema-internal name and is not part of the rename.
///
/// Use ``PersistedAgent`` in new code. Host apps that import both
/// ``ManifoldInference`` and ``ManifoldPersistenceSwiftData`` can refer to
/// the value type as `AgentDefinition` and the SwiftData row as
/// `PersistedAgent` without disambiguation.
public typealias PersistedAgent = ManifoldSchemaV9.Agent
