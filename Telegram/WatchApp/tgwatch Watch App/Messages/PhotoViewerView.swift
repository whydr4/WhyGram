import SwiftUI
import UIKit

/// Full-screen sheet content for viewing a downloaded photo. Aspect-fits the image into
/// the screen with a black background. Standard sheet dismiss (swipe-down / Digital Crown).
///
/// Zoom: the Digital Crown scales 1×…4×, and a double tap toggles between 1× and 2.5×.
/// While zoomed in, dragging pans the photo; at 1× the drag gesture is disabled so the
/// sheet's swipe-down dismiss keeps working.
///
/// Assumes `photo.localPath != nil` (the tap that presents this sheet is gated on
/// download completion).
struct PhotoViewerView: View {
    let photo: PhotoVisual

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
        .focusable()
        .focused($crownFocused)
        .digitalCrownRotation(
            $zoom, from: 1, through: Self.maxZoom, by: 0.1,
            sensitivity: .low, isContinuous: false, isHapticFeedbackEnabled: true
        )
        .onAppear { crownFocused = true }
    }

    @ViewBuilder
    private var image: some View {
        if let path = photo.localPath, let img = UIImage(contentsOfFile: path) {
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
