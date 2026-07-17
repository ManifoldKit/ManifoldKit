# Migration: built-in inference cost estimation removed

**Audience:** consumer
**Status:** historical

**This is a breaking change.** ManifoldKit no longer ships a model-pricing
table or estimates per-call cost. Maintaining accurate, up-to-date pricing for
every provider and model is out of scope; the metric/trace pipeline already
carries the model identifier and token counts, which is everything a consumer
needs to compute cost against its own price table downstream.

## What was removed

| Removed | Where |
|---------|-------|
| `InferenceCostEstimator` (enum + `estimatedCost(...)` + `costTableDate`) | `ManifoldCloudCore` |
| `InferenceMetric.estimatedCostUSD` | `ManifoldInference` |
| `InferenceMetric.isCostApproximate` | `ManifoldInference` |
| `InferenceMetric.costTableDate` | `ManifoldInference` |
| `GenAIAttributeKeys.costUSD` (`gen_ai.usage.cost_usd`) | `ManifoldInference` |
| `GenAIAttributeKeys.costApproximate` (`gen_ai.usage.cost_is_approximate`) | `ManifoldInference` |
| `GenAIAttributeKeys.costTableDate` (`gen_ai.usage.cost_table_date`) | `ManifoldInference` |

The `InferenceMetric` initializer no longer accepts `estimatedCostUSD`,
`isCostApproximate`, or `costTableDate`.

## How to migrate

Compute cost downstream. Every `InferenceMetric` (and the `GenSpan` it adapts
to via `asGenSpan()`) still carries the model and token counts:

- `gen_ai.request.model` (`InferenceMetric.model`)
- `gen_ai.usage.prompt_tokens` (`InferenceMetric.promptTokens`)
- `gen_ai.usage.completion_tokens` (`InferenceMetric.completionTokens`)
- `gen_ai.usage.cached_prompt_tokens` (`InferenceMetric.cachedPromptTokens`)

Join those against your own price table in your sink or OTEL pipeline:

```swift
final class CostingSink: InferenceMetricSink {
    let pricePerMillion: [String: (input: Double, output: Double)] // your table

    func record(_ metric: InferenceMetric) async {
        guard let rate = pricePerMillion[metric.model] else { return }
        let costUSD =
            Double(metric.promptTokens)     / 1_000_000 * rate.input +
            Double(metric.completionTokens) / 1_000_000 * rate.output
        // …emit costUSD however you like (your own span attribute, metric, etc.)
    }
}
```
