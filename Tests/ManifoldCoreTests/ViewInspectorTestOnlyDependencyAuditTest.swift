import Darwin
import Foundation
import XCTest

/// Keeps ViewInspector out of every published ManifoldKit product graph.
///
/// ManifoldKit temporarily selects an unreleased ViewInspector revision for
/// Xcode 27 compatibility. SwiftPM permits a versioned consumer to resolve
/// that graph only while the revision dependency is confined to test targets
/// and pruned. A production edge would make stable ManifoldKit versions
/// unresolvable for downstream packages.
final class ViewInspectorTestOnlyDependencyAuditTest: XCTestCase {

    func test_viewInspectorAppearsOnlyInTestTargetsAndTestSources() throws {
        let repoRoot = try Self.locateRepoRoot()
        let manifest = try Self.evaluatedManifest(at: repoRoot)
        let productionSources = try Self.productionSourceContents(
            under: repoRoot.appendingPathComponent("Sources")
        )

        let violations = Self.violations(
            targets: manifest.targets,
            productionSources: productionSources
        )

        XCTAssertTrue(
            violations.isEmpty,
            """
            ViewInspector must remain test-only while Package.swift selects an
            unreleased revision. A production target edge makes versioned
            ManifoldKit consumers fail dependency resolution:
            \(violations.joined(separator: "\n"))
            """
        )
    }

    func test_sabotage_detectsProductionDependencyShapesAndImport() {
        let targets = [
            TargetDump(
                name: "ProductionProductEdge",
                type: "regular",
                dependencies: [
                    DependencyDump(product: ["ViewInspector", "viewinspector"]),
                ]
            ),
            TargetDump(
                name: "ProductionByNameEdge",
                type: "executable",
                dependencies: [
                    DependencyDump(byName: ["ViewInspector"]),
                ]
            ),
            TargetDump(
                name: "AllowedTests",
                type: "test",
                dependencies: [
                    DependencyDump(product: ["ViewInspector", "ViewInspector"]),
                ]
            ),
        ]
        let sources = [
            ProductionSource(
                path: "Sources/Feature/LeakedInspector.swift",
                content: "public import ViewInspector\n"
            ),
        ]

        let violations = Self.violations(
            targets: targets,
            productionSources: sources
        )

        XCTAssertTrue(
            violations.contains { $0.contains("ProductionProductEdge") },
            "A product dependency with lowercase package identity must be reported; got \(violations)"
        )
        XCTAssertTrue(
            violations.contains { $0.contains("ProductionByNameEdge") },
            "A by-name dependency must be reported; got \(violations)"
        )
        XCTAssertTrue(
            violations.contains { $0.contains("LeakedInspector.swift") },
            "An access-qualified production import must be reported; got \(violations)"
        )
        XCTAssertFalse(
            violations.contains { $0.contains("AllowedTests") },
            "A test-target edge is allowed and must not be reported; got \(violations)"
        )
    }

    func test_sabotage_unknownDependencyEncodingFailsClosed() {
        let changedSchema = Data(
            #"{"targets":[{"name":"FutureShape","type":"regular","dependencies":[{"futureReference":["ViewInspector"]}]}]}"#.utf8
        )

        XCTAssertThrowsError(try JSONDecoder().decode(ManifestDump.self, from: changedSchema))
    }

    func test_sabotage_emptyEvaluatedManifestFailsClosed() {
        let emptyGraph = Data(#"{"targets":[]}"#.utf8)

        XCTAssertThrowsError(try JSONDecoder().decode(ManifestDump.self, from: emptyGraph))
    }

    func test_sabotage_malformedDependencyIdentityFailsClosed() {
        let malformedIdentity = Data(
            #"{"targets":[{"name":"Broken","type":"regular","dependencies":[{"product":[42,"viewinspector",null,null]}]}]}"#.utf8
        )

        XCTAssertThrowsError(try JSONDecoder().decode(ManifestDump.self, from: malformedIdentity))
    }

    func test_sabotage_manifestSubprocessTimeoutTerminatesChild() {
        XCTAssertThrowsError(
            try Self.runProcess(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["5"],
                timeout: 0.05
            )
        ) { error in
            XCTAssertEqual(error as? ProcessRunError, .timedOut)
        }
    }

    func test_sabotage_manifestSubprocessNonzeroExitFailsClosed() {
        XCTAssertThrowsError(
            try Self.runProcess(
                executableURL: URL(fileURLWithPath: "/usr/bin/false"),
                arguments: [],
                timeout: 1
            )
        ) { error in
            XCTAssertEqual(error as? ProcessRunError, .nonzeroExit(1))
        }
    }

    func test_sabotage_manifestSubprocessEmptyOutputFailsClosed() {
        XCTAssertThrowsError(
            try Self.runProcess(
                executableURL: URL(fileURLWithPath: "/usr/bin/true"),
                arguments: [],
                timeout: 1
            )
        ) { error in
            XCTAssertEqual(error as? ProcessRunError, .emptyOutput)
        }
    }

    private struct ManifestDump: Decodable {
        let targets: [TargetDump]

        private enum CodingKeys: String, CodingKey { case targets }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            targets = try container.decode([TargetDump].self, forKey: .targets)
            guard !targets.isEmpty else {
                throw DecodingError.dataCorruptedError(
                    forKey: .targets,
                    in: container,
                    debugDescription: "SwiftPM manifest contained no targets"
                )
            }
        }
    }

    private struct TargetDump: Decodable {
        let name: String
        let type: String
        let dependencies: [DependencyDump]
    }

    private struct DependencyDump: Decodable {
        let referencedNames: [String]

        init(product: [String]) {
            referencedNames = product
        }

        init(byName: [String]) {
            referencedNames = byName
        }

        init(from decoder: Decoder) throws {
            let dynamic = try decoder.container(keyedBy: AnyCodingKey.self)
            guard dynamic.allKeys.count == 1, let key = dynamic.allKeys.first else {
                throw DecodingError.dataCorrupted(
                    .init(
                        codingPath: decoder.codingPath,
                        debugDescription: "Expected one SwiftPM target-dependency encoding"
                    )
                )
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch key.stringValue {
            case CodingKeys.product.rawValue:
                let reference = try container.decode(ProductReference.self, forKey: .product)
                referencedNames = [reference.name, reference.package]
            case CodingKeys.byName.rawValue:
                let reference = try container.decode(NameReference.self, forKey: .byName)
                referencedNames = [reference.name]
            case CodingKeys.target.rawValue:
                let reference = try container.decode(NameReference.self, forKey: .target)
                referencedNames = [reference.name]
            default:
                throw DecodingError.dataCorrupted(
                    .init(
                        codingPath: decoder.codingPath,
                        debugDescription: "Unknown SwiftPM target-dependency encoding: \(key.stringValue)"
                    )
                )
            }
        }

        private enum CodingKeys: String, CodingKey {
            case product
            case byName
            case target
        }
    }

    private struct ProductReference: Decodable {
        let name: String
        let package: String

        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            name = try container.decode(String.self)
            package = try container.decode(String.self)
            if try !container.decodeNil() {
                _ = try container.decode([String: String].self)
            }
            if try !container.decodeNil() {
                _ = try container.decode(DependencyCondition.self)
            }
            guard container.isAtEnd else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unexpected product dependency fields"
                )
            }
        }
    }

    private struct NameReference: Decodable {
        let name: String

        init(from decoder: Decoder) throws {
            var container = try decoder.unkeyedContainer()
            name = try container.decode(String.self)
            if try !container.decodeNil() {
                _ = try container.decode(DependencyCondition.self)
            }
            guard container.isAtEnd else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unexpected named dependency fields"
                )
            }
        }
    }

    private struct DependencyCondition: Decodable {
        let platformNames: [String]
        let traits: [String]

        private enum CodingKeys: String, CodingKey, CaseIterable {
            case platformNames
            case traits
        }

        init(from decoder: Decoder) throws {
            let dynamic = try decoder.container(keyedBy: AnyCodingKey.self)
            let expected = Set(CodingKeys.allCases.map(\.rawValue))
            guard Set(dynamic.allKeys.map(\.stringValue)) == expected else {
                throw DecodingError.dataCorrupted(
                    .init(
                        codingPath: decoder.codingPath,
                        debugDescription: "Unknown SwiftPM dependency-condition encoding"
                    )
                )
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            platformNames = try container.decode([String].self, forKey: .platformNames)
            traits = try container.decode([String].self, forKey: .traits)
        }
    }

    private struct AnyCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            intValue = nil
        }

        init?(intValue: Int) {
            stringValue = String(intValue)
            self.intValue = intValue
        }
    }

    private struct ProductionSource {
        let path: String
        let content: String
    }

    private static func violations(
        targets: [TargetDump],
        productionSources: [ProductionSource]
    ) -> [String] {
        var violations = targets.compactMap { target -> String? in
            guard target.type != "test",
                  target.dependencies.contains(where: referencesViewInspector) else {
                return nil
            }
            return "Production target \"\(target.name)\" depends on ViewInspector"
        }

        violations += productionSources.compactMap { source in
            guard importsViewInspector(source.content) else { return nil }
            return "Production source imports ViewInspector: \(source.path)"
        }

        return violations.sorted()
    }

    private static func referencesViewInspector(_ dependency: DependencyDump) -> Bool {
        dependency.referencedNames.contains {
            $0.caseInsensitiveCompare("ViewInspector") == .orderedSame
        }
    }

    private static func importsViewInspector(_ source: String) -> Bool {
        let pattern = #"\bimport\s+(?:(?:struct|class|enum|protocol|typealias|func|var|let)\s+)?ViewInspector\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            fatalError("Static audit regex failed to compile: \(pattern)")
        }
        return regex.firstMatch(
            in: source,
            range: NSRange(location: 0, length: (source as NSString).length)
        ) != nil
    }

    /// `dump-package` evaluates Package.swift without resolving dependencies
    /// or accessing the network; this is the same source used by
    /// `scripts/affected-suites.sh --generate`.
    private static func evaluatedManifest(at repoRoot: URL) throws -> ManifestDump {
        let scratchPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifold-manifest-audit-\(UUID().uuidString)")
        defer { reportCleanupFailure(at: scratchPath) }
        let output = try runProcess(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: [
                "swift", "package",
                "--package-path", repoRoot.path,
                "--scratch-path", scratchPath.path,
                "dump-package",
            ],
            timeout: 15
        )
        return try JSONDecoder().decode(ManifestDump.self, from: output)
    }

    private static func runProcess(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval
    ) throws -> Data {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifold-process-\(UUID().uuidString)")
        let outputURL = temporaryDirectory.appendingPathComponent("stdout")
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false
        )
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else {
            throw ProcessRunError.outputFileCreationFailed
        }
        defer { reportCleanupFailure(at: temporaryDirectory) }

        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer { outputHandle.closeFile() }
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = outputHandle
        process.standardError = FileHandle.standardError

        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }

        let timedOut = process.isRunning
        if timedOut {
            process.terminate()
            let graceDeadline = Date().addingTimeInterval(0.5)
            while process.isRunning, Date() < graceDeadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }

        process.waitUntilExit()
        outputHandle.synchronizeFile()
        if timedOut { throw ProcessRunError.timedOut }
        guard process.terminationStatus == 0 else {
            throw ProcessRunError.nonzeroExit(process.terminationStatus)
        }

        let output = try Data(contentsOf: outputURL)
        guard !output.isEmpty else { throw ProcessRunError.emptyOutput }
        return output
    }

    private enum ProcessRunError: Error, Equatable {
        case timedOut
        case nonzeroExit(Int32)
        case emptyOutput
        case outputFileCreationFailed
    }

    private static func reportCleanupFailure(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            XCTFail("Could not remove audit temporary directory \(url.path): \(error)")
        }
    }

    private static func productionSourceContents(under sourcesURL: URL) throws -> [ProductionSource] {
        guard let enumerator = FileManager.default.enumerator(
            at: sourcesURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw NSError(
                domain: "ViewInspectorTestOnlyDependencyAuditTest",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not enumerate \(sourcesURL.path)"]
            )
        }

        var sources: [ProductionSource] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            sources.append(ProductionSource(path: fileURL.path, content: content))
        }
        return sources
    }

    private static func locateRepoRoot(filePath: StaticString = #filePath) throws -> URL {
        var directory = URL(fileURLWithPath: "\(filePath)").deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("Package.swift").path
            ) {
                return directory
            }
            directory.deleteLastPathComponent()
        }
        throw NSError(
            domain: "ViewInspectorTestOnlyDependencyAuditTest",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: "Could not locate Package.swift from #filePath"]
        )
    }
}
