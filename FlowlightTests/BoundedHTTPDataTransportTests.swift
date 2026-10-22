import XCTest
@testable import Flowlight

final class BoundedHTTPDataTransportTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    func testAcceptsResponseAtByteLimit() async throws {
        let body = Data("1234".utf8)
        StubURLProtocol.handler = { proto, request in
            proto.send(status: 200, headers: ["Content-Length": "4"], body: body, request: request)
        }
        let transport = makeTransport(maximumBytes: 4)

        let (data, response) = try await transport.data(for: request())

        XCTAssertEqual(data, body)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    func testRejectsDeclaredOversizeBeforeBody() async throws {
        StubURLProtocol.handler = { proto, request in
            proto.send(status: 200, headers: ["Content-Length": "5"], request: request)
        }
        let transport = makeTransport(maximumBytes: 4)

        await XCTAssertThrowsAsyncError(try await transport.data(for: request())) { error in
            XCTAssertEqual(error as? BoundedHTTPDataTransport.TransportError, .responseTooLarge)
        }
    }

    func testRejectsStreamedOversizeWithoutContentLength() async throws {
        StubURLProtocol.handler = { proto, request in
            proto.send(status: 200, body: Data("12345".utf8), request: request)
        }
        let transport = makeTransport(maximumBytes: 4)

        await XCTAssertThrowsAsyncError(try await transport.data(for: request())) { error in
            XCTAssertEqual(error as? BoundedHTTPDataTransport.TransportError, .responseTooLarge)
        }
    }

    func testRejectsRedirectOutsideTrustedOrigin() async throws {
        StubURLProtocol.handler = { proto, request in
            proto.redirect(from: request, to: URL(string: "https://other.example/catalog.json")!)
        }
        let transport = makeTransport(maximumBytes: 16)

        await XCTAssertThrowsAsyncError(try await transport.data(for: request())) { error in
            XCTAssertEqual(error as? BoundedHTTPDataTransport.TransportError, .redirectRejected)
        }
    }

    func testCancellationCompletesPromptlyAndOnlyCancelsItsRequest() async throws {
        StubURLProtocol.handler = { _, _ in }
        let transport = makeTransport(maximumBytes: 16)
        let first = Task { try await transport.data(for: request(path: "first")) }
        let second = Task { try await transport.data(for: request(path: "second")) }
        await Task.yield()

        first.cancel()
        do {
            _ = try await first.value
            XCTFail("cancelled request should throw")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertFalse(second.isCancelled)
        second.cancel()
        _ = try? await second.value
    }

    func testRequestTimeoutFailsHungResponse() async throws {
        StubURLProtocol.handler = { _, _ in }
        let transport = BoundedHTTPDataTransport(
            allowedOrigin: URL(string: "https://trusted.example")!,
            maximumBytes: 16, requestTimeout: 0.05, resourceTimeout: 0.1,
            protocolClasses: [StubURLProtocol.self]
        )

        await XCTAssertThrowsAsyncError(try await transport.data(for: request())) { error in
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
    }

    private func makeTransport(maximumBytes: Int) -> BoundedHTTPDataTransport {
        BoundedHTTPDataTransport(
            allowedOrigin: URL(string: "https://trusted.example")!,
            maximumBytes: maximumBytes,
            protocolClasses: [StubURLProtocol.self]
        )
    }

    private func request(path: String = "catalog") -> URLRequest {
        URLRequest(url: URL(string: "https://trusted.example/\(path).json")!)
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    nonisolated(unsafe) static var handler: ((StubURLProtocol, URLRequest) -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handler
        Self.lock.unlock()
        handler?(self, request)
    }

    override func stopLoading() {}

    func send(status: Int, headers: [String: String] = [:], body: Data? = nil,
              request: URLRequest) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if let body { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    func redirect(from request: URLRequest, to destination: URL) {
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 302, httpVersion: nil,
            headerFields: ["Location": destination.absoluteString]
        )!
        client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: destination), redirectResponse: response)
    }
}

private func XCTAssertThrowsAsyncError<T>(
    _ expression: @autoclosure () async throws -> T,
    _ validate: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected error", file: file, line: line)
    } catch {
        validate(error)
    }
}
