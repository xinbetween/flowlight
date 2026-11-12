import Foundation

/// Product-graph capabilities, kept explicit so the Store build never inherits a Developer-only setup action merely
/// because both products share the same SwiftUI view. These describe shipped mechanics, not current runtime state.
struct ProductCapabilities: Equatable, Sendable {
    var proxyInspection: Bool
    var manualCertificateTrust: Bool
    var automaticSystemProxy: Bool
    var automaticExternalAppConfiguration: Bool
    var trustedProxyAttribution: Bool
    var guardrails: Bool
    var mocks: Bool
    var requestRewrites: Bool
    var responseTransforms: Bool
    var scriptPlugins: Bool

    static var current: ProductCapabilities {
        #if APP_STORE
        ProductCapabilities(
            proxyInspection: true,
            manualCertificateTrust: true,
            automaticSystemProxy: false,
            automaticExternalAppConfiguration: false,
            trustedProxyAttribution: true,
            guardrails: true,
            mocks: true,
            requestRewrites: true,
            responseTransforms: false,
            scriptPlugins: false
        )
        #else
        ProductCapabilities(
            proxyInspection: true,
            manualCertificateTrust: true,
            automaticSystemProxy: true,
            automaticExternalAppConfiguration: true,
            trustedProxyAttribution: true,
            guardrails: true,
            mocks: true,
            requestRewrites: true,
            responseTransforms: true,
            scriptPlugins: true
        )
        #endif
    }
}
