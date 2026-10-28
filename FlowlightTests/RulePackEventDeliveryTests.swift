import XCTest
@testable import Flowlight

final class RulePackEventDeliveryTests: XCTestCase {
    func testRetryReusesDeliveryIdentityAndCommitsOnce() {
        let batches = LockedValue<[RulePackEventBatch]>([])
        let delivered = expectation(description: "retried batch committed")
        let delivery = RulePackEventDelivery(retryDelay: 0.01, attemptTimeout: 1) { batch, claim, completion in
            XCTAssertTrue(claim())
            let attempt = batches.withValue {
                $0.append(batch)
                return $0.count
            }
            completion(attempt == 2)
        }

        delivery.enqueue(event()) { committed in
            XCTAssertTrue(committed)
            delivered.fulfill()
        }
        wait(for: [delivered], timeout: 2)

        let captured = batches.value
        XCTAssertEqual(captured.count, 2)
        XCTAssertEqual(captured[0].deliverySession, captured[1].deliverySession)
        XCTAssertEqual(captured[0].sequence, captured[1].sequence)
        XCTAssertEqual(captured[0].events, captured[1].events)
    }

    func testClaimCanCrossAQueueBoundaryAndCommit() {
        let committed = expectation(description: "cross-queue claim committed")
        let delivery = RulePackEventDelivery(retryDelay: 0.01, attemptTimeout: 1) { _, claim, completion in
            DispatchQueue.global().async {
                XCTAssertTrue(claim())
                completion(true)
            }
        }

        delivery.enqueue(event()) { result in
            XCTAssertTrue(result)
            committed.fulfill()
        }
        wait(for: [committed], timeout: 2)
    }

    func testTwoFailedAttemptsFailOpen() {
        let attempts = LockedValue(0)
        let allowed = expectation(description: "refusal abandoned")
        let delivery = RulePackEventDelivery(retryDelay: 0.01, attemptTimeout: 1) { _, claim, completion in
            XCTAssertTrue(claim())
            attempts.withValue { $0 += 1 }
            completion(false)
        }

        delivery.enqueue(event()) { committed in
            XCTAssertFalse(committed)
            allowed.fulfill()
        }
        wait(for: [allowed], timeout: 2)
        XCTAssertEqual(attempts.value, 2)
    }

    func testMissingAcknowledgementsTimeOutAndFailOpen() {
        let attempts = LockedValue(0)
        let allowed = expectation(description: "timed out refusal abandoned")
        let delivery = RulePackEventDelivery(retryDelay: 0.01, attemptTimeout: 0.03) { _, _, _ in
            attempts.withValue { $0 += 1 }
        }

        delivery.enqueue(event()) { committed in
            XCTAssertFalse(committed)
            allowed.fulfill()
        }
        wait(for: [allowed], timeout: 1)
        XCTAssertEqual(attempts.value, 2)
    }

    func testConcurrentRefusalsHaveIndependentDeadlines() {
        let first = expectation(description: "first failed open")
        let second = expectation(description: "second failed open")
        let started = Date()
        let delivery = RulePackEventDelivery(retryDelay: 0.01, attemptTimeout: 0.03) { _, _, _ in }

        delivery.enqueue(event()) { committed in
            XCTAssertFalse(committed)
            XCTAssertLessThan(Date().timeIntervalSince(started), 0.2)
            first.fulfill()
        }
        delivery.enqueue(event()) { committed in
            XCTAssertFalse(committed)
            XCTAssertLessThan(Date().timeIntervalSince(started), 0.2)
            second.fulfill()
        }

        wait(for: [first, second], timeout: 1)
    }

    func testTimedOutAttemptCannotLaterClaimADurableWrite() {
        let claims = LockedValue<[RulePackEventDelivery.Claim]>([])
        let callbacks = LockedValue<[@Sendable (Bool) -> Void]>([])
        let allowed = expectation(description: "timed out refusal abandoned")
        let delivery = RulePackEventDelivery(retryDelay: 0.01, attemptTimeout: 0.03) { _, claim, completion in
            claims.withValue { $0.append(claim) }
            callbacks.withValue { $0.append(completion) }
        }

        delivery.enqueue(event()) { committed in
            XCTAssertFalse(committed)
            allowed.fulfill()
        }
        wait(for: [allowed], timeout: 1)

        let lateClaims = claims.value
        let lateCallbacks = callbacks.value
        XCTAssertEqual(lateClaims.count, 2)
        XCTAssertTrue(lateClaims.allSatisfy { !$0() })
        lateCallbacks.forEach { $0(true) }
    }

    func testInvalidateFailsAuthorizationOpenAndCancelsUnclaimedWrite() {
        let sinkStarted = expectation(description: "sink started")
        let authorization = expectation(description: "authorization failed open")
        let invalidated = expectation(description: "delivery invalidated")
        let heldClaim = LockedValue<RulePackEventDelivery.Claim?>(nil)
        let delivery = RulePackEventDelivery(retryDelay: 0.01, attemptTimeout: 1) { _, claim, _ in
            heldClaim.withValue { $0 = claim }
            sinkStarted.fulfill()
        }

        delivery.enqueue(event()) { committed in
            XCTAssertFalse(committed)
            authorization.fulfill()
        }
        wait(for: [sinkStarted], timeout: 1)
        delivery.invalidate { invalidated.fulfill() }
        wait(for: [authorization, invalidated], timeout: 1)

        XCTAssertFalse(heldClaim.value?() ?? true)
    }

    private func event() -> RulePackEvent {
        RulePackEvent(
            bucket: 1_700_000_000,
            packID: "official.ads",
            packVersion: "1",
            entryID: 7,
            category: .advertising,
            action: .block,
            count: 1,
            firstAt: 1_700_000_001,
            lastAt: 1_700_000_001,
            bundleID: "com.google.Chrome",
            appName: "Google Chrome",
            agentKey: "com.google.Chrome",
            agentName: "Google Chrome",
            host: "ads.example",
            matchedHost: "ads.example",
            port: 443
        )
    }
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    @discardableResult
    func withValue<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&stored)
    }
}
