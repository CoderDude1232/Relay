//
//  AvatarCropView.swift
//  Relay
//
//  Circular crop for profile and group photos: pinch to zoom, drag to place,
//  and the photo always covers the circle.
//

import SwiftUI
import UIKit

struct AvatarCropView: View {
    let image: UIImage
    let onCancel: () -> Void
    let onChoose: (UIImage) -> Void

    @State private var zoom: CGFloat = 1
    @State private var lastZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    private static let outputSide: CGFloat = 800

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let diameter = max(120, min(geo.size.width, geo.size.height) - 48)
                let base = diameter / max(1, min(image.size.width, image.size.height))
                let shown = CGSize(width: image.size.width * base * zoom, height: image.size.height * base * zoom)
                ZStack {
                    Color.black.ignoresSafeArea()
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: shown.width, height: shown.height)
                        .offset(offset)
                    // Dim everything outside the circle.
                    Rectangle()
                        .fill(.black.opacity(0.55))
                        .mask {
                            Rectangle()
                                .overlay { Circle().frame(width: diameter, height: diameter).blendMode(.destinationOut) }
                                .compositingGroup()
                        }
                        .allowsHitTesting(false)
                    Circle()
                        .stroke(.white.opacity(0.8), lineWidth: 1)
                        .frame(width: diameter, height: diameter)
                        .allowsHitTesting(false)
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .contentShape(.rect)
                .gesture(
                    SimultaneousGesture(
                        MagnifyGesture()
                            .onChanged { value in
                                zoom = min(6, max(1, lastZoom * value.magnification))
                                offset = clamped(offset, shown: scaledSize(base: base), diameter: diameter)
                            }
                            .onEnded { _ in lastZoom = zoom; lastOffset = offset },
                        DragGesture()
                            .onChanged { value in
                                let proposed = CGSize(width: lastOffset.width + value.translation.width,
                                                      height: lastOffset.height + value.translation.height)
                                offset = clamped(proposed, shown: shown, diameter: diameter)
                            }
                            .onEnded { _ in lastOffset = offset }
                    )
                )
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onCancel)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Choose") { onChoose(cropped(diameter: diameter, base: base)) }
                            .fontWeight(.semibold)
                    }
                }
                .accessibilityElement()
                .accessibilityLabel("Photo crop")
                .accessibilityHint("Pinch to zoom and drag to move the photo inside the circle.")
            }
            .navigationTitle("Move and Scale")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }

    private func scaledSize(base: CGFloat) -> CGSize {
        CGSize(width: image.size.width * base * zoom, height: image.size.height * base * zoom)
    }

    /// Keeps the photo covering the circle.
    private func clamped(_ proposed: CGSize, shown: CGSize, diameter: CGFloat) -> CGSize {
        let maxX = max(0, (shown.width - diameter) / 2)
        let maxY = max(0, (shown.height - diameter) / 2)
        return CGSize(width: min(maxX, max(-maxX, proposed.width)),
                      height: min(maxY, max(-maxY, proposed.height)))
    }

    /// The square under the circle, at a fixed size.
    private func cropped(diameter: CGFloat, base: CGFloat) -> UIImage {
        let scale = base * zoom                       // screen points per image point
        let shown = scaledSize(base: base)
        // Top-left of the circle within the displayed image, in image points.
        let originX = ((shown.width - diameter) / 2 - offset.width) / scale
        let originY = ((shown.height - diameter) / 2 - offset.height) / scale
        let side = diameter / scale
        let k = Self.outputSide / side
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: Self.outputSide, height: Self.outputSide), format: format).image { _ in
            image.draw(in: CGRect(x: -originX * k, y: -originY * k,
                                  width: image.size.width * k, height: image.size.height * k))
        }
    }
}

/// A picked photo waiting to be cropped.
struct CropImageItem: Identifiable {
    let id = UUID()
    let image: UIImage
}
