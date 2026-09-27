import SwiftUI

/// The limits on what inspection keeps, in the Advanced section of the Inspect screen.
///
/// Every control here narrows what Flowlight is allowed to hold, so they are shown together rather than scattered
/// through the settings: the point is to be able to see the whole budget at once, and the summary at the bottom is
/// the same sentence the screen shows when inspection is running.
struct InspectionBudgetSection: View {
    @ObservedObject var inspection: InspectionController
    @State private var newHeader = ""
    @State private var newWord = ""

    private var budget: Binding<InspectionBudget> {
        Binding(get: { inspection.budget }, set: { inspection.budget = $0 })
    }

    /// Offered periods, in minutes. 0 is "until I turn it off", which stays available — someone debugging an
    /// overnight job has a real reason for it, and a limit you cannot decline is one people work around.
    private static let sessions = [30, 60, 120, 240, 480, 960, 0]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("What inspection may keep")).font(.caption.bold()).foregroundStyle(.secondary)
            Text(L("Recorded bodies are the most sensitive thing Flowlight holds. These are the limits on them."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            headerPolicy
            if inspection.budget.headerPolicy == .allowlist { allowedHeaders }
            if inspection.budget.headerPolicy == .redactSecrets { extraWords }

            Divider()
            ceilingAndRetention
            Divider()
            session

            Text(inspection.budget.summary)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var headerPolicy: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(L("Headers"), selection: budget.headerPolicy) {
                ForEach(InspectionBudget.HeaderPolicy.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)
            Text(inspection.budget.headerPolicy.detail)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var allowedHeaders: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Headers kept in full")).font(.caption.bold()).foregroundStyle(.secondary)
            chips(Array(inspection.budget.allowedHeaders).sorted()) { name in
                var next = inspection.budget
                next.allowedHeaders.remove(name)
                inspection.budget = next
            }
            HStack {
                TextField(L("x-my-header"), text: $newHeader).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                    .onSubmit(addHeader)
                Button(L("Add"), action: addHeader).disabled(newHeader.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
                Button(L("Restore Defaults")) {
                    var next = inspection.budget
                    next.allowedHeaders = InspectionBudget.defaultAllowedHeaders
                    inspection.budget = next
                }
            }
            if inspection.budget.allowedHeaders.isEmpty {
                Text(L("No headers are allowed, so no header values are kept. The names are still recorded."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var extraWords: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Also treat as credentials")).font(.caption.bold()).foregroundStyle(.secondary)
            Text(L("A header whose name contains one of these is replaced by its length, whatever else it is called. For a vendor whose spelling the built-in list doesn't know."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            chips(inspection.budget.extraSecretWords) { word in
                var next = inspection.budget
                next.extraSecretWords.removeAll { $0 == word }
                inspection.budget = next
            }
            HStack {
                TextField(L("x-acme-licence"), text: $newWord).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                    .onSubmit(addWord)
                Button(L("Add"), action: addWord).disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
            }
        }
    }

    private var ceilingAndRetention: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L("Daily limit on recorded bodies, per app, in MB"))
                TextField("", value: Binding(
                    get: { Int(inspection.budget.dailyBodyBytesPerApp / 1_000_000) },
                    set: { var next = inspection.budget; next.dailyBodyBytesPerApp = Int64(max(0, $0)) * 1_000_000; inspection.budget = next }
                ), format: .number)
                .textFieldStyle(.roundedBorder).frame(width: 70)
                Spacer()
            }
            Text(inspection.budget.dailyBodyBytesPerApp > 0
                 ? L("Past that limit, the exchange is still recorded — time, host, path, status and headers — and only its bodies are dropped.")
                 : L("0 means no ceiling. An agent that resends a long conversation every turn can record a great deal in an afternoon."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            HStack {
                Text(L("Days to keep recorded requests"))
                TextField("", value: Binding(
                    get: { inspection.budget.retentionDays },
                    set: { var next = inspection.budget; next.retentionDays = max(1, $0); inspection.budget = next }
                ), format: .number)
                .textFieldStyle(.roundedBorder).frame(width: 60)
                Spacer()
            }
            Text(L("Applied as soon as you change it, not only at the next cleanup."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var session: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(L("Turn inspection off automatically"), selection: budget.sessionMinutes) {
                ForEach(Self.sessions, id: \.self) { minutes in
                    Text(minutes == 0 ? L("Never — only when I turn it off") : InspectionBudget.duration(minutes: minutes)).tag(minutes)
                }
            }
            .frame(maxWidth: 340)
            if let ends = inspection.sessionEndsAt {
                HStack(spacing: 8) {
                    Image(systemName: "timer").foregroundStyle(.secondary)
                    Text(L("Inspection will turn off at %@", ends.formatted(date: .omitted, time: .shortened)))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(L("Restart the timer")) { inspection.extendSession() }
                        .buttonStyle(.link).font(.caption)
                }
            } else if inspection.budget.sessionMinutes == 0 {
                Text(L("Inspection will run until you switch it off, including across restarts."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func chips(_ items: [String], remove: @escaping (String) -> Void) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                HStack(spacing: 4) {
                    Text(item).font(.caption.monospaced())
                    Button { remove(item) } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("Remove %@", item))
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(.quaternary.opacity(0.6), in: Capsule())
            }
        }
    }

    private func addHeader() {
        let name = newHeader.trimmingCharacters(in: .whitespaces).lowercased()
        guard !name.isEmpty else { return }
        var next = inspection.budget
        next.allowedHeaders.insert(name)
        inspection.budget = next
        newHeader = ""
    }

    private func addWord() {
        let word = newWord.trimmingCharacters(in: .whitespaces).lowercased()
        guard !word.isEmpty, !inspection.budget.extraSecretWords.contains(word) else { return }
        var next = inspection.budget
        next.extraSecretWords.append(word)
        inspection.budget = next
        newWord = ""
    }
}
