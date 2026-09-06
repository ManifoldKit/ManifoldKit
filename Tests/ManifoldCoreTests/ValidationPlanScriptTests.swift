import Foundation
import XCTest

final class ValidationPlanScriptTests: XCTestCase {
    func test_validationPlanFailClosedFixturesPass() throws {
        let root = try Self.locatePackageRoot()
        let script = root.appendingPathComponent("scripts/validation-plan-selftest.sh")
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        process.currentDirectoryURL = root
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, text)
        XCTAssertTrue(text.contains("validation-plan self-test: PASS"), text)
    }

    private static func locatePackageRoot(filePath: StaticString = #filePath) throws -> URL {
        var directory = URL(fileURLWithPath: "\(filePath)").deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return directory
            }
            directory.deleteLastPathComponent()
        }
        throw NSError(
            domain: "ValidationPlanScriptTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not locate Package.swift"]
        )
    }
}
