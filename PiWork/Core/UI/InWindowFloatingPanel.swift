import AppKit
import SwiftUI

struct BoundedFloatingPanelLayout: Equatable {
    let idealWidth: CGFloat
    let idealMaximumHeight: CGFloat
    let inset: CGFloat
    let anchorGap: CGFloat
    let pointerTrailingInset: CGFloat

    init(
        idealWidth: CGFloat,
        idealMaximumHeight: CGFloat,
        inset: CGFloat,
        anchorGap: CGFloat = 12,
        pointerTrailingInset: CGFloat = 48
    ) {
        self.idealWidth = idealWidth
        self.idealMaximumHeight = idealMaximumHeight
        self.inset = inset
        self.anchorGap = anchorGap
        self.pointerTrailingInset = pointerTrailingInset
    }

    func size(in availableBounds: CGSize) -> CGSize {
        CGSize(
            width: min(
                idealWidth,
                max(0, availableBounds.width - inset * 2)
            ),
            height: min(
                idealMaximumHeight,
                max(0, availableBounds.height - inset * 2)
            )
        )
    }

    func placement(
        in availableBounds: CGSize,
        anchoredTo anchorFrame: CGRect?
    ) -> BoundedFloatingPanelPlacement {
        let originY = anchorFrame.map { max(inset, $0.maxY + anchorGap) } ?? inset
        let size = CGSize(
            width: min(idealWidth, max(0, availableBounds.width - inset * 2)),
            height: min(
                idealMaximumHeight,
                max(0, availableBounds.height - originY - inset)
            )
        )
        let maximumOriginX = max(0, availableBounds.width - inset - size.width)
        let minimumOriginX = min(inset, maximumOriginX)

        guard let anchorFrame else {
            return BoundedFloatingPanelPlacement(
                size: size,
                origin: CGPoint(x: maximumOriginX, y: originY),
                pointerX: nil
            )
        }

        let desiredPointerX = max(0, size.width - pointerTrailingInset)
        let originX = min(
            max(anchorFrame.midX - desiredPointerX, minimumOriginX),
            maximumOriginX
        )
        let pointerInset = min(18, size.width / 2)
        let pointerX = min(
            max(anchorFrame.midX - originX, pointerInset),
            max(pointerInset, size.width - pointerInset)
        )
        return BoundedFloatingPanelPlacement(
            size: size,
            origin: CGPoint(x: originX, y: originY),
            pointerX: pointerX
        )
    }
}

struct BoundedFloatingPanelPlacement: Equatable {
    let size: CGSize
    let origin: CGPoint
    let pointerX: CGFloat?
}

struct CatalogInstalledManagerAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>?

    static func reduce(
        value: inout Anchor<CGRect>?,
        nextValue: () -> Anchor<CGRect>?
    ) {
        value = nextValue() ?? value
    }
}

struct InWindowFloatingPanel<Panel: View>: View {
    @Binding private var isPresented: Bool
    private let layout: BoundedFloatingPanelLayout
    private let anchorFrame: CGRect?
    private let panel: () -> Panel

    init(
        isPresented: Binding<Bool>,
        layout: BoundedFloatingPanelLayout,
        anchorFrame: CGRect?,
        @ViewBuilder panel: @escaping () -> Panel
    ) {
        _isPresented = isPresented
        self.layout = layout
        self.anchorFrame = anchorFrame
        self.panel = panel
    }

    @ViewBuilder
    var body: some View {
        if isPresented {
            GeometryReader { geometry in
                let placement = layout.placement(
                    in: geometry.size,
                    anchoredTo: anchorFrame
                )

                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: dismiss)

                    panel()
                        .frame(
                            width: placement.size.width,
                            height: placement.size.height,
                            alignment: .top
                        )
                        .containerShape(
                            RoundedRectangle(cornerRadius: AppCornerRadius.panel, style: .continuous)
                        )
                        .background(AppPalette.raisedSurface)
                        .adaptiveCornerRadius(AppCornerRadius.panel)
                        .overlay(
                            adaptiveRoundedShape(cornerRadius: AppCornerRadius.panel)
                                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                        )
                        .shadow(color: AppPalette.raisedShadow, radius: 18, y: 8)
                        .offset(x: placement.origin.x, y: placement.origin.y)

                    if let pointerX = placement.pointerX {
                        FloatingPanelPointer()
                            .fill(AppPalette.raisedSurface)
                            .overlay(
                                FloatingPanelPointer()
                                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                            )
                            .frame(width: 18, height: 9)
                            .offset(
                                x: placement.origin.x + pointerX - 9,
                                y: placement.origin.y - 8
                            )
                    }
                }
                .background(EscapeKeyMonitor(onEscape: dismiss))
                .onExitCommand(perform: dismiss)
                .clipped()
            }
        }
    }

    private func dismiss() {
        isPresented = false
    }
}

private struct FloatingPanelPointer: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct EscapeKeyMonitor: NSViewRepresentable {
    let onEscape: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onEscape: onEscape)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.view = view
        context.coordinator.start()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onEscape = onEscape
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        weak var view: NSView?
        var onEscape: () -> Void
        private var monitor: Any?

        init(onEscape: @escaping () -> Void) {
            self.onEscape = onEscape
        }

        func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard
                    event.keyCode == 53,
                    let self,
                    event.window === self.view?.window
                else {
                    return event
                }

                self.onEscape()
                return nil
            }
        }

        func stop() {
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }

        deinit {
            stop()
        }
    }
}
