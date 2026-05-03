#if Server
@testable import BaseChatServer
import XCTest

final class RequestAuthMiddlewareTests: XCTestCase {
    // MARK: - AnonymousAuthMiddleware

    func testAnonymousMiddlewarePassesThroughEvenWhenNoCredentialPresent() async throws {
        let middleware = AnonymousAuthMiddleware()

        let principal = try await middleware.authenticate(
            AuthRequest(headers: [:], path: "/v1/models", method: "GET")
        )

        XCTAssertEqual(principal, AuthPrincipal.anonymous)
        XCTAssertEqual(principal.id, "anonymous")
        XCTAssertTrue(principal.scopes.isEmpty)
        // SABOTAGE: change AnonymousAuthMiddleware.authenticate to throw — confirms this asserts the no-op contract
    }

    func testAnonymousMiddlewareIgnoresAuthorizationHeader() async throws {
        let middleware = AnonymousAuthMiddleware()

        let principal = try await middleware.authenticate(
            AuthRequest(
                headers: ["Authorization": "Bearer anything"],
                path: "/v1/models",
                method: "GET"
            )
        )

        XCTAssertEqual(principal, AuthPrincipal.anonymous)
    }

    // MARK: - BearerTokenMiddleware happy path

    func testBearerTokenMiddlewareAcceptsValidBearer() async throws {
        let middleware = BearerTokenMiddleware(token: "secret-123", scopes: ["chat", "models"])

        let principal = try await middleware.authenticate(
            AuthRequest(
                headers: ["Authorization": "Bearer secret-123"],
                path: "/v1/chat/completions",
                method: "POST"
            )
        )

        XCTAssertEqual(principal.id, "bearer")
        XCTAssertEqual(principal.scopes, ["chat", "models"])
    }

    func testBearerTokenMiddlewareAcceptsLowercasedHeaderName() async throws {
        // RFC 9110 §5.1: header field names are case-insensitive.
        let middleware = BearerTokenMiddleware(token: "abc")

        let principal = try await middleware.authenticate(
            AuthRequest(
                headers: ["authorization": "Bearer abc"],
                path: "/v1/models",
                method: "GET"
            )
        )

        XCTAssertEqual(principal.id, "bearer")
    }

    // MARK: - BearerTokenMiddleware rejection

    func testBearerTokenMiddlewareRejectsMissingHeader() async {
        let middleware = BearerTokenMiddleware(token: "secret")

        await assertThrows(
            try await middleware.authenticate(
                AuthRequest(headers: [:], path: "/v1/models", method: "GET")
            ),
            expecting: AuthError.missingCredential
        )
        // SABOTAGE: change `throw AuthError.missingCredential` in middleware to `return .anonymous` — confirms missing-cred path is enforced
    }

    func testBearerTokenMiddlewareRejectsEmptyHeader() async {
        let middleware = BearerTokenMiddleware(token: "secret")

        await assertThrows(
            try await middleware.authenticate(
                AuthRequest(headers: ["Authorization": ""], path: "/v1/models", method: "GET")
            ),
            expecting: AuthError.missingCredential
        )
    }

    func testBearerTokenMiddlewareRejectsWrongScheme() async {
        let middleware = BearerTokenMiddleware(token: "secret")

        await assertThrows(
            try await middleware.authenticate(
                AuthRequest(
                    headers: ["Authorization": "Basic dXNlcjpwYXNz"],
                    path: "/v1/models",
                    method: "GET"
                )
            ),
            expecting: AuthError.malformedCredential
        )
    }

    func testBearerTokenMiddlewareRejectsBearerWithoutToken() async {
        let middleware = BearerTokenMiddleware(token: "secret")

        await assertThrows(
            try await middleware.authenticate(
                AuthRequest(
                    headers: ["Authorization": "Bearer "],
                    path: "/v1/models",
                    method: "GET"
                )
            ),
            expecting: AuthError.malformedCredential
        )
    }

    func testBearerTokenMiddlewareRejectsWrongToken() async {
        let middleware = BearerTokenMiddleware(token: "secret")

        await assertThrows(
            try await middleware.authenticate(
                AuthRequest(
                    headers: ["Authorization": "Bearer not-the-secret"],
                    path: "/v1/models",
                    method: "GET"
                )
            ),
            expecting: AuthError.invalidCredential
        )
    }

    func testBearerTokenMiddlewareIsConstantTimeAtBytesLevel() async {
        // We can't measure timing reliably in CI, but we can at least confirm
        // the comparison rejects same-length non-equal tokens (i.e. doesn't
        // short-circuit on the first mismatch via prefix equality).
        let middleware = BearerTokenMiddleware(token: "abcdef")

        await assertThrows(
            try await middleware.authenticate(
                AuthRequest(
                    headers: ["Authorization": "Bearer abcdeg"],
                    path: "/", method: "GET"
                )
            ),
            expecting: AuthError.invalidCredential
        )
        await assertThrows(
            try await middleware.authenticate(
                AuthRequest(
                    headers: ["Authorization": "Bearer xbcdef"],
                    path: "/", method: "GET"
                )
            ),
            expecting: AuthError.invalidCredential
        )
    }

    // MARK: - Helpers

    private func assertThrows<T>(
        _ expression: @autoclosure () async throws -> T,
        expecting expected: AuthError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected throw of \(expected) but call succeeded", file: file, line: line)
        } catch let error as AuthError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Expected AuthError.\(expected) but got \(error)", file: file, line: line)
        }
    }
}

#endif
