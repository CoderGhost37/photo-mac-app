import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 248, max: 320)
        } detail: {
            HStack(spacing: 0) {
                GridView(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if model.inspectorVisible {
                    Divider()
                    InspectorView(model: model)
                        .frame(width: 300)
                }
            }
            .background(Palette.canvasColor)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        if model.isIndexing {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(model.status)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Slider(value: $model.thumbnailSide, in: 96...240, step: 8)
                        .frame(width: 120)
                        .help("Thumbnail size")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.openConvert()
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    .help("Convert selected files, or drop files in the panel")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.openPDF()
                    } label: {
                        Image(systemName: "doc.richtext")
                    }
                    .help("Make a PDF from the selection, or drop files in the panel")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.inspectorVisible.toggle()
                    } label: {
                        Image(systemName: "sidebar.trailing")
                    }
                    .help("Show or hide the inspector")
                }
            }
        }
        .navigationTitle(model.filterTitle)
        .sheet(item: $model.presentedTool) { tool in
            switch tool {
            case .convert:
                ConvertPanel(model: model, session: model.convertSession)
            case .pdf:
                PDFPanel(model: model, session: model.pdfSession)
            }
        }
    }
}
