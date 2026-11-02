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
    private let showsPointer: Bool
    private let fillsHeight: Bool
    private let panel: () -> Panel

    init(
        isPresented: Binding<Bool>,
        layout: BoundedFloatingPanelLayout,
        anchorFrame: CGRect?,
        showsPointer: Bool = true,
        fillsHeight: Bool = true,
        @ViewBuilder panel: @escaping () -> Panel
    ) {
        _isPresented = isPresented
        self.layout = layout
        self.anchorFrame = anchorFrame
        self.showsPointer = showsPointer
        self.fillsHeight = fillsHeight
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
                            height: fillsHeight ? placement.size.height : nil,
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
                        .background {
                            FloatingPanelDismissMonitor(
                                anchorFrame: anchorFrame?.offsetBy(
                                    dx: -placement.origin.x,
                                    dy: -placement.origin.y
                                ),
                                onDismiss: dismiss
                            )
                        }
                        .offset(x: placement.origin.x, y: placement.origin.y)

                    if showsPointer, let pointerX = placement.pointerX {
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

enum FloatingPanelDismissal {
    static func shouldDismiss(click: CGPoint, panelBounds: CGRect, anchorFrame: CGRect?) -> Bool {
        !panelBounds.contains(click) && !(anchorFrame?.contains(click) ?? false)
    }
}

private struct FloatingPanelDismissMonitor: NSViewRepresentable {
    let anchorFrame: CGRect?
    let onDismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(anchorFrame: anchorFrame, onDismiss: onDismiss)
    }

    func makeNSView(context: Context) -> NSView {
        let view = PanelBoundsView(frame: .zero)
        context.coordinator.view = view
        context.coordinator.start()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.anchorFrame = anchorFrame
        context.coordinator.onDismiss = onDismiss
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    private final class PanelBoundsView: NSView {
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    final class Coordinator {
        weak var view: NSView?
        var anchorFrame: CGRect?
        var onDismiss: () -> Void
        private var monitor: Any?
        private var observers: [NSObjectProtocol] = []

        init(anchorFrame: CGRect?, onDismiss: @escaping () -> Void) {
            self.anchorFrame = anchorFrame
            self.onDismiss = onDismiss
        }

        func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] event in
                guard let self, let view = self.view, let window = view.window else { return event }
                if event.type == .keyDown {
                    guard event.keyCode == 53, event.window === window else { return event }
                    self.onDismiss()
                    return nil
                }
                if event.window === window {
                    let point = view.convert(event.locationInWindow, from: nil)
                    if FloatingPanelDismissal.shouldDismiss(
                        click: point, panelBounds: view.bounds, anchorFrame: self.anchorFrame
                    ) {
                        self.onDismiss()
                    }
                } else if let otherWindow = event.window, otherWindow.level == .normal {
                    self.onDismiss()
                }
                // Outside controls still receive the click that dismissed us.
                return event
            }
            let center = NotificationCenter.default
            observers.append(center.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in self?.onDismiss() })
            observers.append(center.addObserver(
                forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
            ) { [weak self] notification in
                guard let self, let window = self.view?.window,
                      notification.object as? NSWindow === window else { return }
                // Let AppKit finish switching key windows. Menus and sheets
                // belonging to the panel are not clicks outside the panel.
                DispatchQueue.main.async { [weak self, weak window] in
                    guard let self, let window, let keyWindow = NSApp.keyWindow,
                          keyWindow !== window, keyWindow.level == .normal,
                          keyWindow.sheetParent !== window else { return }
                    self.onDismiss()
                }
            })
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
        }

        deinit {
            stop()
        }
    }
}
