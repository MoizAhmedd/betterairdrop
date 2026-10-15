import BetterAirdropCore
import BetterAirdropKit
import SwiftUI

/// Settings → Naming → Finder tags (Pro).
struct FinderTagsSection: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { model.config.finderTags }, set: { v in model.updateConfig { $0.finderTags = v } })) {
                HStack(spacing: 6) { Text("Add Finder tags"); if !model.isPro { ProTag() } }
                Text("The kind (Receipt, Screenshot…) and, for photos, the city, so Finder and Spotlight find them. Undo removes them.")
            }
        } footer: {
            if !model.isPro { ProLine() }
        }
        .disabled(!model.isPro)
    }
}
