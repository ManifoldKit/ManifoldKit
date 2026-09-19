import Foundation
import XCTest

/// Exercises `test-ios-simulator.sh` with fake Xcode and CoreSimulator tools.
/// The script's `--ci` path must select an installed, eligible iPhone by UDID;
/// runner images do not promise a stable device model name.
final class IOSSimulatorDestinationScriptTests: XCTestCase {
    func testCISelectsEligibleIPhoneWithinDeploymentAndSDKBounds() throws {
        let fixture = try Fixture(
            inventory: Self.inventory(
                oldPhone: true,
                eligiblePhone: true,
                futurePhone: true
            )
        )
        defer { fixture.remove() }

        let result = try fixture.run(arguments: ["--ci"])

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("CI mode — resolving an eligible installed iPhone."), result.output)
        XCTAssertTrue(result.output.contains("iPhone 17 CI"), result.output)
        XCTAssertTrue(fixture.xcodebuildArguments().contains("platform=iOS Simulator,id=BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"))
        XCTAssertFalse(fixture.xcodebuildArguments().contains("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
        XCTAssertFalse(fixture.xcodebuildArguments().contains("CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"))
    }

    func testLegacyCINameSelectionFailsOnIPhone17OnlyInventory() throws {
        let fixture = try Fixture(inventory: Self.inventory(oldPhone: false, eligiblePhone: true, futurePhone: false))
        defer { fixture.remove() }
        let legacyScript = try fixture.legacyHardcodedCIScript()

        let result = try fixture.run(
            script: legacyScript,
            arguments: ["--ci"],
            extraEnvironment: ["REJECT_LEGACY_DESTINATION": "1"]
        )

        XCTAssertEqual(result.status, 70, result.output)
        XCTAssertTrue(result.output.contains("Unable to find a device matching"), result.output)
        XCTAssertTrue(fixture.xcodebuildArguments().contains("platform=iOS Simulator,name=iPhone 16"))
    }

    func testExplicitDestinationSkipsInventoryLookup() throws {
        let fixture = try Fixture(inventory: "not JSON")
        defer { fixture.remove() }
        let destination = "platform=iOS Simulator,id=DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD"

        let result = try fixture.run(arguments: ["--destination", destination])

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(fixture.xcodebuildArguments().contains(destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.simctlCalled.path))
    }

    func testNoEligibleIPhoneFailsBeforeLaunchingXcodebuild() throws {
        let fixture = try Fixture(inventory: Self.inventory(oldPhone: true, eligiblePhone: false, futurePhone: true))
        defer { fixture.remove() }

        let result = try fixture.run(arguments: ["--ci"])

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("No available iPhone simulator satisfies iOS 26.0 through 26.2"), result.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.xcodebuildArgumentsPath.path))
    }

    func testMalformedInventoryFailsBeforeLaunchingXcodebuild() throws {
        let fixture = try Fixture(inventory: "{ not-json")
        defer { fixture.remove() }

        let result = try fixture.run(arguments: ["--ci"])

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("Malformed simctl device inventory"), result.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.xcodebuildArgumentsPath.path))
    }

    func testFailedSDKProbeWithValidStdoutFailsBeforeLaunchingXcodebuild() throws {
        let fixture = try Fixture(inventory: Self.inventory(oldPhone: false, eligiblePhone: true, futurePhone: false))
        defer { fixture.remove() }

        let result = try fixture.run(arguments: ["--ci"], extraEnvironment: ["SDK_MODE": "partial-fail"])

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("Could not read the active iOS Simulator SDK"), result.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.xcodebuildArgumentsPath.path))
    }

    func testFailedSimctlProbeFailsBeforeLaunchingXcodebuild() throws {
        let fixture = try Fixture(inventory: Self.inventory(oldPhone: false, eligiblePhone: true, futurePhone: false))
        defer { fixture.remove() }

        let result = try fixture.run(arguments: ["--ci"], extraEnvironment: ["SIMCTL_MODE": "fail"])

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("Could not read the available iOS Simulator inventory"), result.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.xcodebuildArgumentsPath.path))
    }

    func testFailedSDKProbeFailsBeforeLaunchingXcodebuild() throws {
        let fixture = try Fixture(inventory: Self.inventory(oldPhone: false, eligiblePhone: true, futurePhone: false))
        defer { fixture.remove() }

        let result = try fixture.run(arguments: ["--ci"], extraEnvironment: ["SDK_MODE": "fail"])

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains("Could not read the active iOS Simulator SDK"), result.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.xcodebuildArgumentsPath.path))
    }

    private static func inventory(oldPhone: Bool, eligiblePhone: Bool, futurePhone: Bool) -> String {
        let old = oldPhone ? """
        "com.apple.CoreSimulator.SimRuntime.iOS-25-4": [{
          "name": "iPhone 15 Old", "udid": "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", "state": "Shutdown", "isAvailable": true
        }],
        """ : ""
        let eligible = eligiblePhone ? """
        "com.apple.CoreSimulator.SimRuntime.iOS-26-2": [{
          "name": "iPhone 17 CI", "udid": "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", "state": "Shutdown", "isAvailable": true
        }, {
          "name": "iPad Pro CI", "udid": "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE", "state": "Booted", "isAvailable": true
        }],
        """ : ""
        let future = futurePhone ? """
        "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [{
          "name": "iPhone 18 Future", "udid": "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC", "state": "Booted", "isAvailable": true
        }]
        """ : ""
        return "{ \"devices\": { \(old)\(eligible)\(future) } }"
            .replacingOccurrences(of: ", }", with: "}")
    }

    private final class Fixture {
        let root: URL
        let bin: URL
        let inventoryPath: URL
        let xcodebuildArgumentsPath: URL
        let simctlCalled: URL

        init(inventory: String) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("ios-simulator-destination-\(UUID().uuidString)")
            bin = root.appendingPathComponent("bin")
            inventoryPath = root.appendingPathComponent("inventory.json")
            xcodebuildArgumentsPath = root.appendingPathComponent("xcodebuild-arguments.txt")
            simctlCalled = root.appendingPathComponent("simctl-called")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try inventory.write(to: inventoryPath, atomically: true, encoding: .utf8)
            try Self.writeExecutable(named: "xcrun", in: bin, content: """
            #!/bin/bash
            if [ "${1:-}" = "simctl" ]; then
              : > "$SIMCTL_CALLED"
              if [ "${SIMCTL_MODE:-json}" = "fail" ]; then
                echo "simctl fixture failure" >&2
                exit 73
              fi
              cat "$SIMCTL_FIXTURE"
              exit 0
            fi
            exit 91
            """)
            try Self.writeExecutable(named: "xcodebuild", in: bin, content: """
            #!/bin/bash
            if [ "${1:-}" = "-showsdks" ]; then
              if [ "${SDK_MODE:-ok}" = "fail" ]; then
                echo "SDK fixture failure" >&2
                exit 74
              fi
              printf '%s\\n' 'iOS Simulator SDKs:' '    Simulator - iOS 26.2    -sdk iphonesimulator26.2'
              if [ "${SDK_MODE:-ok}" = "partial-fail" ]; then
                echo "SDK fixture failed after stdout" >&2
                exit 74
              fi
              exit 0
            fi
            if [ "${1:-}" = "test" ]; then
              printf '%s\\n' "$@" > "$FAKE_XCODEBUILD_ARGUMENTS"
              case "$*" in
                *"platform=iOS Simulator,name=iPhone 16"*)
                  if [ "${REJECT_LEGACY_DESTINATION:-0}" = "1" ]; then
                    echo "xcodebuild: error: Unable to find a device matching the provided destination specifier" >&2
                    exit 70
                  fi
                  ;;
              esac
              exit 0
            fi
            exit 92
            """)
        }

        func run(arguments: [String], extraEnvironment: [String: String] = [:]) throws -> (status: Int32, output: String) {
            try run(
                script: Self.repositoryRoot().appendingPathComponent("scripts/test-ios-simulator.sh"),
                arguments: arguments,
                extraEnvironment: extraEnvironment
            )
        }

        func run(script: URL, arguments: [String], extraEnvironment: [String: String] = [:]) throws -> (status: Int32, output: String) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = [script.path] + arguments
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "\(bin.path):\(environment["PATH"] ?? "")"
            environment["SIMCTL_FIXTURE"] = inventoryPath.path
            environment["SIMCTL_CALLED"] = simctlCalled.path
            environment["FAKE_XCODEBUILD_ARGUMENTS"] = xcodebuildArgumentsPath.path
            for (key, value) in extraEnvironment { environment[key] = value }
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            process.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "<non-UTF8 output>"
            return (process.terminationStatus, output)
        }

        func legacyHardcodedCIScript() throws -> URL {
            let fixtureScriptDirectory = root.appendingPathComponent("scripts")
            try FileManager.default.createDirectory(at: fixtureScriptDirectory, withIntermediateDirectories: true)
            let destination = fixtureScriptDirectory.appendingPathComponent("test-ios-simulator.sh")
            var source = try String(contentsOf: Self.repositoryRoot().appendingPathComponent("scripts/test-ios-simulator.sh"), encoding: .utf8)
            let current = """
            elif [[ "$CI_MODE" -eq 1 ]]; then
                echo "CI mode — resolving an eligible installed iPhone." >&2
                resolve_inventory_destination
            else
            """
            let legacy = """
            elif [[ "$CI_MODE" -eq 1 ]]; then
                DESTINATION="platform=iOS Simulator,name=iPhone 16"
            else
            """
            XCTAssertTrue(source.contains(current), "The fixture must mutate the real current CI branch, not a hand-written approximation.")
            source = source.replacingOccurrences(of: current, with: legacy)
            try source.write(to: destination, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
            try """
            // swift-tools-version: 6.1
            import PackageDescription
            let package = Package(name: "Fixture", platforms: [.iOS("26.0")])
            """.write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
            return destination
        }

        func xcodebuildArguments() -> String {
            (try? String(contentsOf: xcodebuildArgumentsPath, encoding: .utf8)) ?? ""
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        private static func writeExecutable(named name: String, in directory: URL, content: String) throws {
            let path = directory.appendingPathComponent(name)
            try content.write(to: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        }

        private static func repositoryRoot() -> URL {
            var candidate = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            for _ in 0..<5 {
                if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("Package.swift").path) {
                    return candidate
                }
                candidate.deleteLastPathComponent()
            }
            fatalError("Could not locate repository root from \(#filePath)")
        }
    }
}
