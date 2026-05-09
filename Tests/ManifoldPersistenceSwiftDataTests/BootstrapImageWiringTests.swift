import XCTest
import ManifoldRuntime
@testable import ManifoldPersistenceSwiftData
@testable import ManifoldInference

/// Defends the image-generation opt-in wiring on ``ManifoldBootstrap`` (PR 9 / umbrella #1002).
///
/// Hosts that do not pass `imageGenerationService:` get identical behaviour to
/// pre-PR-9 bootstrap — both image properties remain `nil`. Hosts that opt in
/// get a wired ``ImageGenerationRuntime`` backed by the supplied service and
/// the bootstrap's persistence layer.
@MainActor
final class BootstrapImageWiringTests: XCTestCase {

    // MARK: - Helpers

    private func makeBootstrap(
        imageGenerationService: ImageGenerationService? = nil
    ) throws -> ManifoldBootstrap {
        let originalConfiguration = ManifoldConfiguration.shared
        addTeardownBlock { ManifoldConfiguration.shared = originalConfiguration }

        return try ManifoldBootstrap(
            configuration: ManifoldConfiguration(
                appName: "Bootstrap Image Wiring Tests",
                bundleIdentifier: "com.manifoldkit.tests.bootstrap-image-wiring.\(UUID().uuidString)"
            ),
            imageGenerationService: imageGenerationService,
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() }
        )
    }

    // MARK: - Test 1: Default init — image stack is nil

    func test_defaultInit_imagePropertiesAreNil() throws {
        // Hosts that don't pass `imageGenerationService:` must not observe any
        // image-generation surface on the bootstrap — neither the service nor
        // the runtime. Sabotage the nil-assignment of `imageGenerationService`
        // or `imageRuntime` in ManifoldBootstrap.init and this test fails.
        let bootstrap = try makeBootstrap()

        XCTAssertNil(
            bootstrap.imageGenerationService,
            "imageGenerationService must be nil when not provided at init time"
        )
        XCTAssertNil(
            bootstrap.imageRuntime,
            "imageRuntime must be nil when imageGenerationService is nil"
        )
    }

    // MARK: - Test 2: Opt-in init — image stack is wired

    func test_optInInit_imagePropertiesAreNonNil() throws {
        // When the host passes an `ImageGenerationService`, both the service
        // and the runtime must be present and the runtime must hold the
        // exact service instance that was supplied.
        //
        // Sabotage: comment out `self.imageRuntime = ImageGenerationRuntime(...)`
        // in ManifoldBootstrap.init and this test fails on `imageRuntime` nil check.
        let service = ImageGenerationService()
        let bootstrap = try makeBootstrap(imageGenerationService: service)

        XCTAssertNotNil(
            bootstrap.imageGenerationService,
            "imageGenerationService must be non-nil when provided at init time"
        )
        XCTAssertNotNil(
            bootstrap.imageRuntime,
            "imageRuntime must be non-nil when imageGenerationService is provided"
        )
        XCTAssertTrue(
            bootstrap.imageGenerationService === service,
            "imageGenerationService must be the exact instance passed to init"
        )
    }
}
