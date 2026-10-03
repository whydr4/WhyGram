import ImageIO
import SwiftUI
import UIKit

/// Full-screen sheet content for viewing a downloaded photo. Aspect-fits the image into
/// the screen with a black background. Standard sheet dismiss (swipe-down / Digital Crown).
///
/// Zoom: the Digital Crown scales 1×…4×, and a double tap toggles between 1× and 2.5×.
/// While zoomed in, dragging pans the photo; at 1× the drag gesture is disabled so the
/// sheet's swipe-down dismiss keeps working.
///
/// Sharpness: the chat bubble's ~320px variant is shown first, while the larger
/// `photo.full` variant (≤1280px) downloads; it replaces the small one once ready.
/// The download is cancelled if the viewer closes first.
///
/// Assumes `photo.localPath != nil` (the tap that presents this sheet is gated on
/// download completion).
struct PhotoViewerView: View {
    let photo: PhotoVisual

    @Environment(ChatHistoryStore.self) private var store
    @State private var fullImage: UIImage?
    @State private var zoom: Double = 1
    @State private var offset: CGSize = .zero
    @State private var dragStartOffset: CGSize = .zero
    @FocusState private var crownFocused: Bool

    private static let maxZoom: Double = 4
    private static let doubleTapZoom: Double = 2.5

    private var isZoomed: Bool { zoom > 1.01 }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                image
                    .scaleEffect(zoom)
                    .offset(offset)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(panGesture(in: geo.size), including: isZoomed ? .all : .subviews)
            .onTapGesture(count: 2) { toggleZoom() }
            .onChange(of: zoom) { _, _ in
                // Zooming out shrinks the pannable area; keep the photo inside it.
                offset = clampedOffset(offset, in: geo.size)
                dragStartOffset = offset
            }
        }
        .overlay(alignment: .topTrailing) {
            if photo.full != nil, fullImage == nil {
                ProgressView().controlSize(.mini).padding(6)
            }
        }
        .task(id: fullPath) {
            guard let path = fullPath else { return }
            fullImage = await Self.downsampledImage(path: path, maxPixelSize: 1280)
        }
        .onAppear {
            if let full = photo.full, fullPath == nil {
                store.requestFileDownload(fileId: full.fileId, priority: 16)
            }
        }
        .onDisappear {
            if let full = photo.full, fullImage == nil {
                store.cancelFileDownload(fileId: full.fileId)
            }
        }
        .focusable()
        .focused($crownFocused)
        .digitalCrownRotation(
            $zoom, from: 1, through: Self.maxZoom, by: 0.1,
            sensitivity: .low, isContinuous: false, isHapticFeedbackEnabled: true
        )
        .onAppear { crownFocused = true }
    }

    /// Local path of the sharper variant once downloaded. Read through the store so the
    /// view updates when the download completes (`photo` is a snapshot).
    private var fullPath: String? {
        guard let full = photo.full else { return nil }
        if let file = store.fileSnapshot(fileId: full.fileId),
           file.local.isDownloadingCompleted, !file.local.path.isEmpty {
            return file.local.path
        }
        return full.localPath
    }

    /// Decodes off the main thread, scaled so the longer side is at most `maxPixelSize`.
    private static func downsampledImage(path: String, maxPixelSize: Int) async -> UIImage? {
        await Task.detached(priority: .userInitiated) {
            let url = URL(fileURLWithPath: path) as CFURL
            guard let source = CGImageSourceCreateWithURL(url, [kCGImageSourceShouldCache: false] as CFDictionary) else {
                return nil
            }
            let options = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ] as CFDictionary
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
            return UIImage(cgImage: cgImage)
        }.value
    }

    @ViewBuilder
    private var image: some View {
        if let fullImage {
            Image(uiImage: fullImage)
                .resizable()
                .scaledToFit()
        } else if let path = photo.localPath, let img = UIImage(contentsOfFile: path) {
            Image(uiImage: img)
                .resizable()
                .scaledToFit()
        } else if let data = photo.minithumbnail, let img = UIImage(data: data) {
            Image(uiImage: img)
                .resizable()
                .scaledToFit()
                .blur(radius: 4)
        } else {
            Color.gray.opacity(0.3)
        }
    }

    private func toggleZoom() {
        withAnimation(.easeInOut(duration: 0.2)) {
            if isZoomed {
                zoom = 1
                offset = .zero
                dragStartOffset = .zero
            } else {
                zoom = Self.doubleTapZoom
            }
        }
    }

    private func panGesture(in container: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                offset = clampedOffset(
                    CGSize(width: dragStartOffset.width + value.translation.width,
                           height: dragStartOffset.height + value.translation.height),
                    in: container
                )
            }
            .onEnded { _ in dragStartOffset = offset }
    }

    /// The aspect-fit size of the photo inside `container` at 1×.
    private func fittedSize(in container: CGSize) -> CGSize {
        guard photo.width > 0, photo.height > 0 else { return container }
        let scale = min(container.width / CGFloat(photo.width), container.height / CGFloat(photo.height))
        return CGSize(width: CGFloat(photo.width) * scale, height: CGFloat(photo.height) * scale)
    }

    /// Limits panning so the zoomed photo never leaves a gap at the screen edge.
    private func clampedOffset(_ proposed: CGSize, in container: CGSize) -> CGSize {
        let fitted = fittedSize(in: container)
        let maxX = max(0, (fitted.width * zoom - container.width) / 2)
        let maxY = max(0, (fitted.height * zoom - container.height) / 2)
        return CGSize(width: min(max(proposed.width, -maxX), maxX),
                      height: min(max(proposed.height, -maxY), maxY))
    }
}
