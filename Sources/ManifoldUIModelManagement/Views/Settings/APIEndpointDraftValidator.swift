import ManifoldRuntime
import ManifoldInference

/// Validates in-progress endpoint edits against ManifoldKit's canonical endpoint policy.
///
/// Drafts are validated through ``APIEndpointRecord/validateBaseURL()`` so the
/// editor doesn't materialise a SwiftData `@Model` just to reuse the policy.
enum APIEndpointDraftValidator {
    static func validate(
        provider: APIProvider,
        baseURL: String,
        modelName: String
    ) -> Result<Void, APIEndpointValidationReason> {
        let trimmedURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        let record = APIEndpointRecord(
            name: provider.displayName,
            provider: provider,
            baseURL: trimmedURL.isEmpty ? nil : trimmedURL,
            modelName: trimmedModel.isEmpty ? nil : trimmedModel
        )
        return record.validateBaseURL()
    }
}
