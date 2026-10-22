import Foundation

/// Request-level seam shared by update clients. It preserves conditional headers and final response metadata in tests.
typealias HTTPDataTransport = @Sendable (URLRequest) async throws -> (Data, URLResponse)
