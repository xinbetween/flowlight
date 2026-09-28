import SwiftUI

/// Shown before the first row leaves, and again whenever what would leave has changed.
///
/// The sheet is ordered the way the question is actually asked: where it goes, whether anyone on the path can
/// read it, what exactly travels, and what is attached to the request. Approving is the affirmative button but
/// not the default one — a disclosure you can dismiss with Return without reading is a disclosure in name.
struct ExportDisclosureSheet: View {
    let disclosure: ExportDisclosure
    let approve: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showFields = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Before anything leaves this Mac")).font(.title3.bold())
                Text(L("Flowlight asks every app on this Mac to say what it sends and where. This is that, for Flowlight."))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 14)

            Form {
                Section(L("Where it goes")) {
                    LabeledContent(L("Collector"), value: disclosure.endpoint)
                    LabeledContent(L("Format"), value: disclosure.mode.title)
                    if disclosure.encrypted {
                        Label(L("Encrypted in transit (HTTPS)."), systemImage: "lock.fill")
                            .foregroundStyle(.green).font(.callout)
                    } else {
                        // Said in these words rather than shown as a scheme and left to the reader. The whole
                        // point of the screen is that nobody has to infer the consequence.
                        Label(L("Not encrypted. Everything below crosses the network in the clear, readable by anything on the path."),
                              systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section(L("What is attached to the request")) {
                    if disclosure.headerNames.isEmpty {
                        Text(L("No headers.")).foregroundStyle(.secondary)
                    } else {
                        ForEach(disclosure.headerNames, id: \.self) { name in
                            LabeledContent(name) {
                                // Names, never values. A screen that printed a token to prove it was being
                                // sent would be the thing it is warning about.
                                Text(L("value kept in the Keychain, not shown")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section {
                    DisclosureGroup(isExpanded: $showFields) {
                        ForEach(disclosure.items) { item in
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    Text(item.key).font(.caption.monospaced())
                                    if item.perRequest {
                                        Text(L("once per request")).font(.caption2)
                                            .padding(.horizontal, 5).padding(.vertical, 1)
                                            .background(.quaternary, in: Capsule())
                                    }
                                }
                                Text(item.what).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.vertical, 1)
                        }
                    } label: {
                        Text(L("Exactly these %lld fields", disclosure.fieldCount)).font(.headline)
                    }
                } footer: {
                    Text(L("Nothing that HTTPS inspection records can reach an export: no request or response headers, no bodies, no tool calls, no decrypted exchange. Some of the fields listed above travel inside the format's own envelope rather than as a named key, which changes where they appear in your collector, not whether they leave."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)

            HStack {
                Text(L("Flowlight will ask again if any of this changes."))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(L("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("Send This")) {
                    approve()
                    dismiss()
                }
                // Deliberately not `.defaultAction`: approving is a decision, not the way out of a dialog.
            }
            .padding(.top, 10)
        }
        .padding(16)
        .frame(width: 620, height: 640)
    }
}
