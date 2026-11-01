import Foundation

struct DurableEventDelivery<Event> {
    var token: UUID
    var clientGeneration: UInt64
    var eventIDs: Set<UUID>
    var events: [Event]
}

struct DurableDeliveryHealth<Channel: Hashable> {
    private(set) var pending: Set<Channel> = []
    private(set) var failed: Set<Channel> = []

    var isHealthy: Bool { pending.isEmpty && failed.isEmpty }

    mutating func begin(_ channel: Channel) {
        pending.insert(channel)
    }

    mutating func succeeded(_ channel: Channel) {
        pending.remove(channel)
        failed.remove(channel)
    }

    mutating func failed(_ channel: Channel) {
        pending.remove(channel)
        failed.insert(channel)
    }

    mutating func reset() {
        pending.removeAll()
        failed.removeAll()
    }
}

struct DurableEventQueue<Event> {
    private(set) var pending: [Event] = []
    private(set) var inFlight: DurableEventDelivery<Event>?

    var isEmpty: Bool { pending.isEmpty }

    mutating func append(_ event: Event) {
        pending.append(event)
    }

    mutating func begin(
        clientGeneration: UInt64,
        limit: Int,
        id: (Event) -> UUID?
    ) -> DurableEventDelivery<Event>? {
        guard inFlight == nil else { return nil }
        let events = Array(pending.prefix(max(1, limit)))
        guard !events.isEmpty else { return nil }
        let eventIDs = Set(events.compactMap(id))
        guard eventIDs.count == events.count else { return nil }
        let delivery = DurableEventDelivery(
            token: UUID(),
            clientGeneration: clientGeneration,
            eventIDs: eventIDs,
            events: events
        )
        inFlight = delivery
        return delivery
    }

    @discardableResult
    mutating func complete(
        token: UUID,
        clientGeneration: UInt64,
        committed: Bool,
        id: (Event) -> UUID?
    ) -> Bool {
        guard let delivery = inFlight,
              delivery.token == token,
              delivery.clientGeneration == clientGeneration else { return false }
        inFlight = nil
        if committed {
            pending.removeAll { event in
                id(event).map(delivery.eventIDs.contains) ?? false
            }
        }
        return true
    }

    mutating func resetDelivery() {
        inFlight = nil
    }
}
