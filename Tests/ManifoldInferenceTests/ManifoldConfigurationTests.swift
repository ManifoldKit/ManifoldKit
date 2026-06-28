import XCTest
@testable import ManifoldInference

final class ManifoldConfigurationTests: XCTestCase {

    // MARK: - Default Initializer

    func test_defaultInit_appName() {
        let config = ManifoldConfiguration()
        XCTAssertEqual(config.appName, "ManifoldKit")
    }

    func test_defaultInit_bundleIdentifier() {
        let config = ManifoldConfiguration()
        XCTAssertEqual(config.bundleIdentifier, "com.manifoldkit")
    }

    func test_defaultInit_modelsDirectoryName() {
        let config = ManifoldConfiguration()
        XCTAssertEqual(config.modelsDirectoryName, "Models")
    }

    // MARK: - Derived Identifiers

    func test_logSubsystem_equalsBundleIdentifier() {
        let config = ManifoldConfiguration(bundleIdentifier: "com.example.app")
        XCTAssertEqual(config.logSubsystem, "com.example.app")
    }

    func test_keychainServiceName_appendsApikeys() {
        let config = ManifoldConfiguration(bundleIdentifier: "com.example.app")
        XCTAssertEqual(config.keychainServiceName, "com.example.app.apikeys")
    }

    func test_downloadSessionIdentifier_appendsModeldownload() {
        let config = ManifoldConfiguration(bundleIdentifier: "com.example.app")
        XCTAssertEqual(config.downloadSessionIdentifier, "com.example.app.modeldownload")
    }

    func test_pendingDownloadsKey_appendsPendingDownloads() {
        let config = ManifoldConfiguration(bundleIdentifier: "com.example.app")
        XCTAssertEqual(config.pendingDownloadsKey, "com.example.app.pendingDownloads")
    }

    func test_memoryPressureQueueLabel_appendsMemoryPressure() {
        let config = ManifoldConfiguration(bundleIdentifier: "com.example.app")
        XCTAssertEqual(config.memoryPressureQueueLabel, "com.example.app.memory-pressure")
    }

    // MARK: - Custom Initializer

    func test_customInit_propagatesAllFields() {
        let features = ManifoldConfiguration.Features(showContextIndicator: false)
        let config = ManifoldConfiguration(
            appName: "MyApp",
            bundleIdentifier: "com.myapp",
            modelsDirectoryName: "LLMs",
            features: features
        )

        XCTAssertEqual(config.appName, "MyApp")
        XCTAssertEqual(config.bundleIdentifier, "com.myapp")
        XCTAssertEqual(config.modelsDirectoryName, "LLMs")
        XCTAssertFalse(config.features.showContextIndicator)
    }

    // MARK: - Features Default Values

    func test_features_defaultInit_allTrue() {
        let features = ManifoldConfiguration.Features()

        XCTAssertTrue(features.showContextIndicator)
        XCTAssertTrue(features.showMemoryIndicator)
        XCTAssertTrue(features.showChatExport)
        XCTAssertTrue(features.showModelDownload)
        XCTAssertTrue(features.showStorageTab)
        XCTAssertTrue(features.showGenerationSettings)
        XCTAssertTrue(features.showAdvancedSettings)
        XCTAssertTrue(features.showCloudAPIManagement)
        XCTAssertTrue(features.showUpgradeHint)
        XCTAssertTrue(features.showAudioInput, "showAudioInput must default to true to preserve existing composer behavior")
        XCTAssertTrue(features.showImageAttachment, "showImageAttachment must default to true to preserve existing composer behavior")
    }

    // MARK: - Features Custom Init

    func test_features_customInit_respectsEachFlag() {
        let features = ManifoldConfiguration.Features(
            showContextIndicator: false,
            showMemoryIndicator: true,
            showChatExport: false,
            showModelDownload: true,
            showStorageTab: false,
            showGenerationSettings: true,
            showAdvancedSettings: false,
            showCloudAPIManagement: true,
            showUpgradeHint: false,
            showAudioInput: false,
            showImageAttachment: true
        )

        XCTAssertFalse(features.showAudioInput)
        XCTAssertTrue(features.showImageAttachment)
        XCTAssertFalse(features.showContextIndicator)
        XCTAssertTrue(features.showMemoryIndicator)
        XCTAssertFalse(features.showChatExport)
        XCTAssertTrue(features.showModelDownload)
        XCTAssertFalse(features.showStorageTab)
        XCTAssertTrue(features.showGenerationSettings)
        XCTAssertFalse(features.showAdvancedSettings)
        XCTAssertTrue(features.showCloudAPIManagement)
        XCTAssertFalse(features.showUpgradeHint)
    }

    func test_features_singleFlagDisabled_othersRemainTrue() {
        let features = ManifoldConfiguration.Features(showUpgradeHint: false)

        XCTAssertTrue(features.showContextIndicator)
        XCTAssertTrue(features.showMemoryIndicator)
        XCTAssertTrue(features.showChatExport)
        XCTAssertTrue(features.showModelDownload)
        XCTAssertTrue(features.showStorageTab)
        XCTAssertTrue(features.showGenerationSettings)
        XCTAssertTrue(features.showAdvancedSettings)
        XCTAssertTrue(features.showCloudAPIManagement)
        XCTAssertFalse(features.showUpgradeHint)
    }

    // MARK: - File Protection

    func test_defaultInit_fileProtectionClass_isCompleteUntilFirstUserAuth() {
        let config = ManifoldConfiguration()
        XCTAssertEqual(
            config.fileProtectionClass,
            .completeUntilFirstUserAuthentication,
            "Default Data Protection class must stay at completeUntilFirstUserAuthentication — it balances at-rest protection with background-task compatibility"
        )
    }

    func test_customInit_fileProtectionClass_canOptOut() {
        let config = ManifoldConfiguration(fileProtectionClass: nil)
        XCTAssertNil(config.fileProtectionClass)
    }

    func test_customInit_fileProtectionClass_canRaiseToComplete() {
        let config = ManifoldConfiguration(fileProtectionClass: .complete)
        XCTAssertEqual(config.fileProtectionClass, .complete)
    }
}
