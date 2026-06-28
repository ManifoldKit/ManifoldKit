import Foundation
import ManifoldInference
import os

/// A ``TraceSink`` that exports ``GenSpan`` values to an OTLP/HTTP endpoint.
///
/// Each recorded span is immediately serialised to the OTLP/JSON wire format
/// and POSTed to the configured endpoint. The typical endpoint for an
/// OpenTelemetry Collector or Jaeger-with-OTLP is
/// `http://localhost:4318/v1/traces`.
///
/// Export failures are logged as warnings and silently swallowed — callers
/// that need reliable delivery should instrument the sink or use a collector
/// with persistent storage.
///
/// ## Usage
///
/// ```swift
/// let otlpSink = OTLPTraceSink(endpoint: URL(string: "http://localhost:4318/v1/traces")!)
/// backend.traceSink = otlpSink
/// ```
public actor OTLPTraceSink: TraceSink {

    private let endpoint: URL
    private let session: URLSession
    private static let logger = Logger(subsystem: "com.manifoldkit", category: "OTLPTraceSink")

    public init(
        endpoint: URL,
        session: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.session = session
    }

    // MARK: - TraceSink

    public func record(_ span: GenSpan) async {
        let data: Data
        do {
            data = try OTLPSpanSerializer.payload(for: span)
        } catch {
            Self.logger.warning("OTLPTraceSink: serialisation failed for span '\(span.name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
            return
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data

        do {
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                Self.logger.warning("OTLPTraceSink: collector returned HTTP \(http.statusCode) for span '\(span.name, privacy: .public)'")
            }
        } catch {
            Self.logger.warning("OTLPTraceSink: export failed for span '\(span.name, privacy: .public)': \(error.localizedDescription, privacy: .public)")
        }
    }
}
