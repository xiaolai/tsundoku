import SwiftUI
import TsundokuCore

/// The reviewed crop editor. The image is a snapshot; moving the crop here
/// never moves Kindle or turns a page.
struct CropEditorView: View {
    let preview: PagePreview
    @Binding var crop: CaptureCrop
    let onRefresh: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var active: DragHandle?
    @State private var dragStart: CGRect?
    @State private var zoom: CGFloat = 1
    @State private var outputThumbnail: CGImage?

    private enum DragHandle: String, CaseIterable {
        case topLeft
        case topRight
        case bottomLeft
        case bottomRight
        case move
    }

    private var contentSize: CGSize { preview.contentRect.size }
    private var contentLocal: CGRect {
        CGRect(
            x: preview.contentRect.minX - preview.windowFrame.minX,
            y: preview.contentRect.minY - preview.windowFrame.minY,
            width: preview.contentRect.width,
            height: preview.contentRect.height)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Preview Current Page")
                    .font(.headline)
                Spacer()
                Button("Refresh Preview", action: onRefresh)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            GeometryReader { geometry in
                let scale = fittedScale(in: geometry.size)
                let imageSize = CGSize(
                    width: contentSize.width * scale,
                    height: contentSize.height * scale)
                let imageOrigin = CGPoint(
                    x: (geometry.size.width - imageSize.width) / 2,
                    y: (geometry.size.height - imageSize.height) / 2)
                let viewRect = viewRect(
                    scale: scale, imageOrigin: imageOrigin)
                ZStack(alignment: .topLeading) {
                    Image(decorative: preview.image, scale: 1)
                        .resizable()
                        .frame(
                            width: imageSize.width, height: imageSize.height)
                        .offset(x: imageOrigin.x, y: imageOrigin.y)
                    Path { path in
                        path.addRect(
                            CGRect(origin: .zero, size: geometry.size))
                        path.addRect(viewRect)
                    }
                    .fill(
                        Color.black.opacity(0.42),
                        style: FillStyle(eoFill: true))
                    Rectangle()
                        .stroke(Color.accentColor, lineWidth: 2)
                        .frame(width: viewRect.width, height: viewRect.height)
                        .offset(x: viewRect.minX, y: viewRect.minY)
                    handles(
                        viewRect: viewRect, scale: scale,
                        imageOrigin: imageOrigin)
                }
                .contentShape(Rectangle())
                .onTapGesture {}
                .gesture(
                    moveGesture(scale: scale, imageOrigin: imageOrigin))
            }
            .frame(minHeight: 320)
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            controls
            HStack {
                Text(
                    "Crop \(Int(crop.rect.width))×\(Int(crop.rect.height)) pt "
                        + "· ratio "
                        + String(format: "%.3f", crop.rect.width
                            / max(1, crop.rect.height))
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
                Text("A4 output 595×842 pt")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(minWidth: 680, minHeight: 620)
        .focusable()
        .onKeyPress(.leftArrow) { nudge(dx: -1, dy: 0); return .handled }
        .onKeyPress(.rightArrow) { nudge(dx: 1, dy: 0); return .handled }
        .onKeyPress(.upArrow) { nudge(dx: 0, dy: -1); return .handled }
        .onKeyPress(.downArrow) { nudge(dx: 0, dy: 1); return .handled }
        .task(id: crop) {
            try? await Task.sleep(for: .milliseconds(60))
            outputThumbnail = makeOutputImage()
        }
    }

    private var controls: some View {
        HStack(spacing: 16) {
            // The capture writes A4 pages, so the crop always keeps the
            // A4 ratio; there is no free-form mode to switch to.
            Label("A4 ratio 210:297", systemImage: "lock")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Reset Crop") {
                crop = CaptureCrop(
                    rect: preview.pageBox.offsetBy(
                        dx: -preview.windowFrame.minX,
                        dy: -preview.windowFrame.minY))
                    .a4Locked(in: contentLocal)
            }
            .help("Restore the measured page box")
            numericField(
                "X", value: crop.rect.minX,
                set: { value in
                    var rect = crop.rect
                    rect.origin.x = value
                    crop = CaptureCrop(rect: clamped(rect))
                })
            numericField(
                "Y", value: crop.rect.minY,
                set: { value in
                    var rect = crop.rect
                    rect.origin.y = value
                    crop = CaptureCrop(rect: clamped(rect))
                })
            numericField(
                "W", value: crop.rect.width,
                set: { value in
                    var rect = crop.rect
                    rect.size.width = max(40, value)
                    rect.size.height = rect.width / CaptureCrop.a4Ratio
                    crop = CaptureCrop(rect: clamped(rect))
                })
            numericField(
                "H", value: crop.rect.height,
                set: { value in
                    var rect = crop.rect
                    rect.size.height = max(40, value)
                    rect.size.width = rect.height * CaptureCrop.a4Ratio
                    crop = CaptureCrop(rect: clamped(rect))
                })
            if let output = outputThumbnail {
                Image(decorative: output, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 46, height: 62)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .help("Output preview")
            }
            Spacer()
            Text("Zoom")
                .font(.caption)
            Slider(value: $zoom, in: 1...3)
                .frame(width: 120)
            Text(String(format: "%.1f×", zoom))
                .font(.caption.monospacedDigit())
                .frame(width: 36, alignment: .trailing)
        }
    }

    private func handles(
        viewRect: CGRect, scale: CGFloat, imageOrigin: CGPoint
    ) -> some View {
        let points: [(DragHandle, CGPoint)] = [
            (.topLeft, CGPoint(x: viewRect.minX, y: viewRect.minY)),
            (.topRight, CGPoint(x: viewRect.maxX, y: viewRect.minY)),
            (.bottomLeft, CGPoint(x: viewRect.minX, y: viewRect.maxY)),
            (.bottomRight, CGPoint(x: viewRect.maxX, y: viewRect.maxY)),
        ]
        return ForEach(points.indices, id: \.self) { index in
            let (handle, point) = points[index]
            Circle()
                .fill(Color.accentColor)
                .frame(width: 14, height: 14)
                .overlay(Circle().stroke(.white, lineWidth: 2))
                .position(point)
                .highPriorityGesture(
                    resizeGesture(
                        handle: handle, scale: scale,
                        imageOrigin: imageOrigin))
                .accessibilityLabel("\(handle.rawValue) crop handle")
                .accessibilityValue(
                    "\(Int(crop.rect.width)) by \(Int(crop.rect.height)) points"
                )
                .accessibilityAdjustableAction { direction in
                    let step: CGFloat = direction == .increment ? 2 : -2
                    resizeFromKeyboard(handle: handle, step: step)
                }
        }
    }

    private func makeOutputImage() -> CGImage? {
        try? preview.croppedImage(for: crop)
    }

    private func fittedScale(in size: CGSize) -> CGFloat {
        guard contentSize.width > 0, contentSize.height > 0 else {
            return 1
        }
        return min(
            size.width / contentSize.width,
            size.height / contentSize.height) * zoom
    }

    private func viewRect(scale: CGFloat, imageOrigin: CGPoint) -> CGRect {
        let contentLocal = CGRect(
            x: preview.windowFrame.minX + crop.rect.minX
                - preview.contentRect.minX,
            y: preview.windowFrame.minY + crop.rect.minY
                - preview.contentRect.minY,
            width: crop.rect.width,
            height: crop.rect.height)
        return CGRect(
            x: imageOrigin.x + contentLocal.minX * scale,
            y: imageOrigin.y + contentLocal.minY * scale,
            width: contentLocal.width * scale,
            height: contentLocal.height * scale)
    }

    private func moveGesture(scale: CGFloat, imageOrigin: CGPoint)
        -> some Gesture
    {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragStart == nil { dragStart = crop.rect }
                guard let start = dragStart, scale > 0 else { return }
                let dx = value.translation.width / scale
                let dy = value.translation.height / scale
                crop = CaptureCrop(
                    rect: clamped(
                        start.offsetBy(dx: dx, dy: dy)))
            }
            .onEnded { _ in dragStart = nil }
    }

    private func resizeGesture(
        handle: DragHandle, scale: CGFloat, imageOrigin: CGPoint
    ) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragStart == nil { dragStart = crop.rect }
                guard let start = dragStart, scale > 0 else { return }
                let dx = value.translation.width / scale
                let dy = value.translation.height / scale
                crop = CaptureCrop(
                    rect: resize(
                        start: start, handle: handle, dx: dx, dy: dy))
            }
            .onEnded { _ in dragStart = nil }
    }

    /// Only the width is dragged; the height follows from the A4 ratio, and
    /// the anchor is the opposite corner.
    private func resize(
        start: CGRect, handle: DragHandle, dx: CGFloat, dy: CGFloat
    ) -> CGRect {
        let width: CGFloat
        switch handle {
        case .topLeft, .bottomLeft:
            width = start.width - dx
        case .topRight, .bottomRight:
            width = start.width + dx
        case .move:
            return start
        }
        let maxWidth = min(
            contentLocal.width,
            contentLocal.height * CaptureCrop.a4Ratio)
        let clampedWidth = max(120, min(width, maxWidth))
        let height = clampedWidth / CaptureCrop.a4Ratio
        switch handle {
        case .topLeft:
            return clamped(CGRect(
                x: start.maxX - clampedWidth, y: start.maxY - height,
                width: clampedWidth, height: height))
        case .topRight:
            return clamped(CGRect(
                x: start.minX, y: start.maxY - height,
                width: clampedWidth, height: height))
        case .bottomLeft:
            return clamped(CGRect(
                x: start.maxX - clampedWidth, y: start.minY,
                width: clampedWidth, height: height))
        case .bottomRight:
            return clamped(CGRect(
                x: start.minX, y: start.minY,
                width: clampedWidth, height: height))
        case .move:
            return start
        }
    }

    private func clamped(_ rect: CGRect) -> CGRect {
        var result = rect
        result.size.width = max(
            40, min(result.width, contentLocal.width))
        let maxWidth = min(
            contentLocal.width,
            contentLocal.height * CaptureCrop.a4Ratio)
        result.size.width = min(
            max(40, min(result.width, contentLocal.width)), maxWidth)
        result.size.height = result.width / CaptureCrop.a4Ratio
        result.origin.x = min(
            max(contentLocal.minX, result.origin.x),
            contentLocal.maxX - result.width)
        result.origin.y = min(
            max(contentLocal.minY, result.origin.y),
            contentLocal.maxY - result.height)
        return result
    }

    private func numericField(
        _ label: String, value: CGFloat, set: @escaping (CGFloat) -> Void
    ) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(
                label,
                value: Binding(
                    get: { Double(value) },
                    set: { set(CGFloat($0)) }),
                format: .number.precision(.fractionLength(0)))
                .frame(width: 48)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func nudge(dx: CGFloat, dy: CGFloat) {
        crop = CaptureCrop(
            rect: clamped(crop.rect.offsetBy(dx: dx, dy: dy)))
    }

    private func resizeFromKeyboard(handle: DragHandle, step: CGFloat) {
        crop = CaptureCrop(
            rect: resize(
                start: crop.rect, handle: handle, dx: step, dy: step))
    }
}
