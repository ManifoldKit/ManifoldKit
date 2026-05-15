/// Public alias for the current SwiftData chat message model.
///
/// Points to ``ManifoldSchemaV7/ChatMessage``, which adds `kindRaw` and
/// `citationsJSON` columns over the V4 baseline. Older schema versions
/// (V4–V6) still reference ``ManifoldSchemaV4/ChatMessage`` directly in
/// their `models` lists so their checksums remain stable.
public typealias ChatMessage = ManifoldSchemaV7.ChatMessage
