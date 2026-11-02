import PhotoIndex
import SwiftUI

struct SidebarView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Stillroom")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Palette.inkColor)
                Text("On this Mac")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            List {
                Section("Library") {
                    row(
                        title: "All Items",
                        symbol: "square.grid.2x2",
                        count: model.counts.enabledTotal,
                        active: model.selectedSourceID == nil && model.selectedKind == nil,
                        showsToggle: false,
                        enabled: true
                    ) {
                        model.selectAll()
                    }
                }

                Section("Media Types") {
                    ForEach(MediaKind.allCases, id: \.self) { kind in
                        row(
                            title: Format.mediaTitle(kind),
                            symbol: Format.mediaSymbol(kind),
                            count: model.counts.byMediaKind[kind] ?? 0,
                            active: model.selectedKind == kind,
                            showsToggle: false,
                            enabled: true
                        ) {
                            model.select(kind: kind)
                        }
                    }
                }

                Section("Sources") {
                    ForEach(model.sources) { source in
                        row(
                            title: source.displayName,
                            symbol: Format.sourceSymbol(source.kind),
                            count: model.counts.bySource[source.id] ?? 0,
                            active: model.selectedSourceID == source.id,
                            showsToggle: true,
                            enabled: source.enabled,
                            toggle: Binding(
                                get: { source.enabled },
                                set: { model.setEnabled($0, sourceID: source.id) }
                            )
                        ) {
                            model.select(sourceID: source.id)
                        }
                        .contextMenu {
                            if source.kind == .folder {
                                Button("Remove from Stillroom") {
                                    model.removeFolder(source)
                                }
                            }
                        }
                    }
                    Button {
                        model.addFolder()
                    } label: {
                        Label("Add Folder…", systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.accentColor)
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .background(Palette.sidebarColor)
    }

    private func row(
        title: String,
        symbol: String,
        count: Int,
        active: Bool,
        showsToggle: Bool,
        enabled: Bool,
        toggle: Binding<Bool>? = nil,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Button(action: action) {
                HStack(spacing: 8) {
                    Image(systemName: symbol)
                        .frame(width: 16)
                        .foregroundStyle(active ? Palette.accentColor : .secondary)
                    Text(title)
                        .foregroundStyle(enabled ? Palette.inkColor : .secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(Format.count(count))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if showsToggle, let toggle {
                Toggle("", isOn: toggle)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .help(enabled ? "Included in the library" : "Turn on to index this source")
            }
        }
        .padding(.vertical, 2)
        .listRowBackground(
            active ? Palette.accentColor.opacity(0.16) : Color.clear
        )
    }
}
