import SwiftUI

struct TranscriptView: View {
    @ObservedObject var store: TranscriptStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                if store.entries.isEmpty {
                    Text("No transcripts yet.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(store.entries) { entry in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(entry.text)
                                .font(.body)
                            Text(entry.timestamp.formatted(.dateTime.month(.abbreviated).day().year().hour().minute().second()))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
            .navigationTitle("Transcripts")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Clear") { store.clear() }
                }
            }
        }
    }
}
