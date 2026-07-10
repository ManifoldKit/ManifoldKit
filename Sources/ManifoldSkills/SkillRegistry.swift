import Foundation

/// Actor-isolated lookup table keyed by skill `name` and aliases.
///
/// Last-wins on name + alias collisions across `load(_:)` calls so a
/// project-level skill set can override a user-level one (`SkillLoader`
/// already orders by precedence; the registry preserves it).
public actor SkillRegistry {

    private var skillsByName: [String: SkillDefinition] = [:]
    private var skillByAlias: [String: String] = [:]

    public init() {}

    /// Inserts skills, overwriting any prior entry sharing a name or alias.
    public func load(_ skills: [SkillDefinition]) {
        for skill in skills {
            skillsByName[skill.name] = skill
            for alias in skill.aliases {
                skillByAlias[alias] = skill.name
            }
        }
    }

    /// Looks up by canonical name or alias.
    public func skill(named identifier: String) -> SkillDefinition? {
        if let direct = skillsByName[identifier] {
            return direct
        }
        if let canonical = skillByAlias[identifier] {
            return skillsByName[canonical]
        }
        return nil
    }

    /// All registered skills, sorted by name for stable enumeration.
    public func all() -> [SkillDefinition] {
        skillsByName.values.sorted { $0.name < $1.name }
    }
}
