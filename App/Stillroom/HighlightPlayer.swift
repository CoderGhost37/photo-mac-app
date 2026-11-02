import PhotoIndex
import SwiftUI

/// Full-window playback. Tap the right side or press the right arrow to move on.
/// The story advances on its own. Escape closes it. Nothing is written.
struct HighlightPlayer: View {
    var story: HighlightStory
    var index: Int
    var started: Date
    var image: NSImage?
    var onBack: () -> Void
    var onForward: () -> Void
    var onClose: () -> Void

    @FocusState private var focused: Bool
    private let beat: TimeInterval = 4.5

    var body: some View {
        ZStack {
            Color.black.opacity(0.94)
                .ignoresSafeArea()
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(48)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                    .allowsHitTesting(false)
            }
            GeometryReader { proxy in
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        if location.x < proxy.size.width * 0.35 {
                            onBack()
                        } else {
                            onForward()
                        }
                    }
            }
            VStack(spacing: 16) {
                progress
                    .allowsHitTesting(false)
                Spacer(minLength: 0)
                    .allowsHitTesting(false)
                HStack {
                    Text(story.title)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .allowsHitTesting(false)
                    Spacer(minLength: 0)
                        .allowsHitTesting(false)
                    Text("\(index + 1) of \(max(story.count, 1))")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.8))
                        .allowsHitTesting(false)
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(.white.opacity(0.16))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .help("Close")
                }
            }
            .padding(20)
        }
        .focusable()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.rightArrow) {
            onForward()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            onBack()
            return .handled
        }
        .onKeyPress(.escape) {
            onClose()
            return .handled
        }
        .onExitCommand(perform: onClose)
        .task(id: index) {
            try? await Task.sleep(nanoseconds: UInt64(beat * 1_000_000_000))
            guard !Task.isCancelled else { return }
            onForward()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(story.title)
    }

    private var progress: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { context in
            HStack(spacing: 4) {
                ForEach(0..<max(story.count, 1), id: \.self) { item in
                    Capsule()
                        .fill(.white.opacity(0.28))
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(.white)
                                .scaleEffect(x: fraction(for: item, at: context.date), y: 1, anchor: .leading)
                        }
                        .frame(height: 3)
                }
            }
        }
    }

    private func fraction(for item: Int, at date: Date) -> CGFloat {
        if item < index { return 1 }
        if item > index { return 0 }
        let elapsed = date.timeIntervalSince(started)
        return CGFloat(min(1, max(0, elapsed / beat)))
    }
}

struct HighlightPlayback: View {
    var model: AppModel
    var story: HighlightStory
    @State private var image: NSImage?

    var body: some View {
        HighlightPlayer(
            story: story,
            index: min(model.playingIndex, max(story.count - 1, 0)),
            started: model.playingStarted,
            image: image,
            onBack: { model.rewindStory() },
            onForward: { model.advanceStory() },
            onClose: { model.stopStory() }
        )
        .task(id: "\(story.id)|\(model.playingIndex)") {
            image = nil
            guard story.assetIDs.indices.contains(model.playingIndex) else { return }
            let id = story.assetIDs[model.playingIndex]
            guard let asset = model.asset(id: id), let thumbnails = model.thumbnails else { return }
            let loaded = await thumbnails.image(for: asset, pointSize: 1400, scale: 2, quality: .preview)
            if !Task.isCancelled {
                image = loaded
            }
        }
    }
}
