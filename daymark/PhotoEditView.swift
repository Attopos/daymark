import SwiftUI
import UIKit

struct PhotoEditView: View {
    let image: UIImage
    let onSave: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var rotationSteps = 0
    @State private var cropRect: CGRect = .zero
    @State private var imageBounds: CGRect = .zero
    @State private var initialized = false

    private var displayImage: UIImage {
        rotationSteps % 4 == 0 ? image : image.rotatedByQuarterTurns(rotationSteps)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                GeometryReader { geometry in
                    let imgSize = displayImage.size
                    let fitSize = aspectFitSize(imgSize, in: geometry.size)
                    let bounds = CGRect(
                        x: (geometry.size.width - fitSize.width) / 2,
                        y: (geometry.size.height - fitSize.height) / 2,
                        width: fitSize.width,
                        height: fitSize.height
                    )

                    ZStack {
                        Image(uiImage: displayImage)
                            .resizable()
                            .scaledToFit()
                            .frame(width: fitSize.width, height: fitSize.height)
                            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)

                        CropOverlay(cropRect: $cropRect, imageBounds: bounds)
                    }
                    .onAppear {
                        if !initialized {
                            imageBounds = bounds
                            cropRect = bounds
                            initialized = true
                        }
                    }
                    .onChange(of: rotationSteps) {
                        imageBounds = bounds
                        cropRect = bounds
                    }
                }

                controlBar
            }
            .background(.black)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(.white)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { applyAndSave() }
                        .fontWeight(.semibold)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
    }

    private var controlBar: some View {
        HStack(spacing: 40) {
            Button {
                rotationSteps = (rotationSteps + 1) % 4
            } label: {
                VStack(spacing: 6) {
                    Image(systemName: "rotate.right")
                        .font(.system(size: 22, weight: .medium))
                    Text("Rotate")
                        .font(.caption2)
                }
                .foregroundStyle(.white)
            }

            Button {
                cropRect = imageBounds
            } label: {
                VStack(spacing: 6) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 22, weight: .medium))
                    Text("Reset Crop")
                        .font(.caption2)
                }
                .foregroundStyle(.white)
            }
        }
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity)
        .background(.black)
    }

    private func aspectFitSize(_ imageSize: CGSize, in containerSize: CGSize) -> CGSize {
        let scale = min(containerSize.width / imageSize.width, containerSize.height / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    private func applyAndSave() {
        let edited = displayImage

        let scaleX = edited.size.width * edited.scale / imageBounds.width
        let scaleY = edited.size.height * edited.scale / imageBounds.height
        let pixelRect = CGRect(
            x: (cropRect.minX - imageBounds.minX) * scaleX,
            y: (cropRect.minY - imageBounds.minY) * scaleY,
            width: cropRect.width * scaleX,
            height: cropRect.height * scaleY
        )

        if let cgImage = edited.cgImage?.cropping(to: pixelRect) {
            onSave(UIImage(cgImage: cgImage))
        } else {
            onSave(edited)
        }
        dismiss()
    }
}

// MARK: - Crop Overlay

private struct CropOverlay: View {
    @Binding var cropRect: CGRect
    let imageBounds: CGRect

    @State private var dragMode: DragMode = .none
    @State private var dragStartRect: CGRect = .zero

    private let handleRadius: CGFloat = 14
    private let minSize: CGFloat = 50

    private enum DragMode {
        case none, move, topLeft, topRight, bottomLeft, bottomRight
    }

    var body: some View {
        ZStack {
            CropMaskShape(hole: cropRect, bounds: imageBounds)
                .fill(.black.opacity(0.55), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)

            Rectangle()
                .strokeBorder(.white.opacity(0.8), lineWidth: 1)
                .frame(width: cropRect.width, height: cropRect.height)
                .position(x: cropRect.midX, y: cropRect.midY)
                .allowsHitTesting(false)

            gridLines
                .allowsHitTesting(false)

            Group {
                cornerHandle(at: CGPoint(x: cropRect.minX, y: cropRect.minY))
                cornerHandle(at: CGPoint(x: cropRect.maxX, y: cropRect.minY))
                cornerHandle(at: CGPoint(x: cropRect.minX, y: cropRect.maxY))
                cornerHandle(at: CGPoint(x: cropRect.maxX, y: cropRect.maxY))
            }
            .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if dragMode == .none {
                        dragMode = hitTest(value.startLocation)
                        dragStartRect = cropRect
                    }
                    update(translation: value.translation)
                }
                .onEnded { _ in
                    dragMode = .none
                }
        )
    }

    private var gridLines: some View {
        Canvas { context, _ in
            let thirdW = cropRect.width / 3
            let thirdH = cropRect.height / 3
            for i in 1...2 {
                var vLine = Path()
                vLine.move(to: CGPoint(x: cropRect.minX + thirdW * CGFloat(i), y: cropRect.minY))
                vLine.addLine(to: CGPoint(x: cropRect.minX + thirdW * CGFloat(i), y: cropRect.maxY))
                context.stroke(vLine, with: .color(.white.opacity(0.3)), lineWidth: 0.5)

                var hLine = Path()
                hLine.move(to: CGPoint(x: cropRect.minX, y: cropRect.minY + thirdH * CGFloat(i)))
                hLine.addLine(to: CGPoint(x: cropRect.maxX, y: cropRect.minY + thirdH * CGFloat(i)))
                context.stroke(hLine, with: .color(.white.opacity(0.3)), lineWidth: 0.5)
            }
        }
    }

    private func cornerHandle(at point: CGPoint) -> some View {
        Circle()
            .fill(.white)
            .frame(width: handleRadius, height: handleRadius)
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            .position(point)
    }

    private func hitTest(_ point: CGPoint) -> DragMode {
        let corners: [(CGPoint, DragMode)] = [
            (CGPoint(x: cropRect.minX, y: cropRect.minY), .topLeft),
            (CGPoint(x: cropRect.maxX, y: cropRect.minY), .topRight),
            (CGPoint(x: cropRect.minX, y: cropRect.maxY), .bottomLeft),
            (CGPoint(x: cropRect.maxX, y: cropRect.maxY), .bottomRight),
        ]
        for (pos, mode) in corners {
            if hypot(point.x - pos.x, point.y - pos.y) < handleRadius * 2.5 {
                return mode
            }
        }
        if cropRect.contains(point) { return .move }
        return .none
    }

    private func update(translation: CGSize) {
        switch dragMode {
        case .none:
            break
        case .move:
            var r = dragStartRect.offsetBy(dx: translation.width, dy: translation.height)
            r.origin.x = max(imageBounds.minX, min(r.origin.x, imageBounds.maxX - r.width))
            r.origin.y = max(imageBounds.minY, min(r.origin.y, imageBounds.maxY - r.height))
            cropRect = r
        case .topLeft:
            let x = clamp(dragStartRect.minX + translation.width, lo: imageBounds.minX, hi: dragStartRect.maxX - minSize)
            let y = clamp(dragStartRect.minY + translation.height, lo: imageBounds.minY, hi: dragStartRect.maxY - minSize)
            cropRect = CGRect(x: x, y: y, width: dragStartRect.maxX - x, height: dragStartRect.maxY - y)
        case .topRight:
            let maxX = clamp(dragStartRect.maxX + translation.width, lo: dragStartRect.minX + minSize, hi: imageBounds.maxX)
            let y = clamp(dragStartRect.minY + translation.height, lo: imageBounds.minY, hi: dragStartRect.maxY - minSize)
            cropRect = CGRect(x: dragStartRect.minX, y: y, width: maxX - dragStartRect.minX, height: dragStartRect.maxY - y)
        case .bottomLeft:
            let x = clamp(dragStartRect.minX + translation.width, lo: imageBounds.minX, hi: dragStartRect.maxX - minSize)
            let maxY = clamp(dragStartRect.maxY + translation.height, lo: dragStartRect.minY + minSize, hi: imageBounds.maxY)
            cropRect = CGRect(x: x, y: dragStartRect.minY, width: dragStartRect.maxX - x, height: maxY - dragStartRect.minY)
        case .bottomRight:
            let maxX = clamp(dragStartRect.maxX + translation.width, lo: dragStartRect.minX + minSize, hi: imageBounds.maxX)
            let maxY = clamp(dragStartRect.maxY + translation.height, lo: dragStartRect.minY + minSize, hi: imageBounds.maxY)
            cropRect = CGRect(x: dragStartRect.minX, y: dragStartRect.minY, width: maxX - dragStartRect.minX, height: maxY - dragStartRect.minY)
        }
    }

    private func clamp(_ value: CGFloat, lo: CGFloat, hi: CGFloat) -> CGFloat {
        max(lo, min(value, hi))
    }
}

private struct CropMaskShape: Shape {
    let hole: CGRect
    let bounds: CGRect

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(bounds)
        path.addRect(hole)
        return path
    }
}

// MARK: - UIImage Rotation

extension UIImage {
    func rotatedByQuarterTurns(_ turns: Int) -> UIImage {
        let normalizedTurns = ((turns % 4) + 4) % 4
        guard normalizedTurns != 0, cgImage != nil else { return self }

        let radians = CGFloat(normalizedTurns) * .pi / 2
        var newSize = size
        if normalizedTurns % 2 != 0 {
            newSize = CGSize(width: size.height, height: size.width)
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return UIGraphicsImageRenderer(size: newSize, format: format).image { ctx in
            ctx.cgContext.translateBy(x: newSize.width / 2, y: newSize.height / 2)
            ctx.cgContext.rotate(by: radians)
            draw(in: CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height))
        }
    }
}
