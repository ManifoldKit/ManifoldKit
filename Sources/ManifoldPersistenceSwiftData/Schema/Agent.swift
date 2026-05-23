/// The SwiftData persistence model for an agent persona. Renamed at the
/// module-public layer to ``PersistedAgent`` to avoid shadowing
/// ``ManifoldInference/Agent`` (the value type that flows through the
/// runtime). The underlying `@Model` class remains
/// ``ManifoldSchemaV9/Agent`` so existing SwiftData stores stay valid.
///
/// Use ``PersistedAgent`` in new code. Host apps that import both
/// ``ManifoldInference`` and ``ManifoldPersistenceSwiftData`` can refer to
/// the value type as `Agent` and the SwiftData row as `PersistedAgent`
/// without disambiguation.
public typealias PersistedAgent = ManifoldSchemaV9.Agent

/// Back-compat alias for code that referenced ``Agent`` directly before
/// the F3 disambiguation. Prefer ``PersistedAgent`` in new code.
///
/// This alias may be deprecated in a future major version once host apps
/// have migrated to the disambiguated name.
public typealias Agent = ManifoldSchemaV9.Agent
