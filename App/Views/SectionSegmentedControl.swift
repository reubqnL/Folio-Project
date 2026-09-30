import SwiftUI
import AppKit

/// Padding inside each segment, on each side of its label.
///
/// This is the one number that controls how wide the bar is. Equal segments
/// are all sized to the widest label ("Connections"), so this padding is
/// charged three times over.
private let sectionSwitcherLabelPadding: CGFloat = 14

/// The Notes / Roadmap / Connections switcher, as a real `NSSegmentedControl`,
/// with two behaviours the stock control does not have.
final class SectionSwitcherSegmentedControl: NSSegmentedControl {
    /// Give every segment the same width: the widest label's, plus the same
    /// padding either side.
    ///
    /// `segmentDistribution = .fillEqually` was tried first and is not enough.
    /// It equalises the segments to the widest label *as that label is already
    /// padded*, so "Connections" ends up sitting close to its own edges while
    /// "Notes" floats in a pool of space — three segments of equal width that
    /// still do not look like the same thing. Setting the widths outright makes
    /// the three identical and puts equal padding around every label, which is
    /// what "all the same size" has to mean to look deliberate.
    ///
    /// Called from `makeNSView` and `updateNSView`. It is not re-run if the
    /// control's font changes on its own, because nothing in this app changes
    /// it; if that ever becomes false this needs to be called from a `font`
    /// observer as well.
    func equalizeSegmentWidths(labelPadding: CGFloat) {
        let font = self.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        var widest: CGFloat = 0
        for index in 0..<segmentCount {
            let label = label(forSegment: index) ?? ""
            let width = (label as NSString).size(withAttributes: [.font: font]).width
            widest = max(widest, width)
        }
        guard widest > 0 else { return }
        let segmentWidth = (widest + labelPadding * 2).rounded(.up)
        for index in 0..<segmentCount where self.width(forSegment: index) != segmentWidth {
            setWidth(segmentWidth, forSegment: index)
        }
    }

    /// Show the slashed-circle cursor while disabled.
    ///
    /// A disabled `NSSegmentedControl` leaves the arrow cursor over itself, so
    /// it looks exactly like a control that would work, and the click that does
    /// nothing is the only way to find out otherwise.
    override var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            // Cursor rectangles are cached per window; without this the old
            // cursor stays in force until the pointer leaves and returns.
            window?.invalidateCursorRects(for: self)
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard !isEnabled else { return }
        addCursorRect(bounds, cursor: .operationNotAllowed)
    }
}

/// The Notes / Roadmap / Connections switcher, as a real `NSSegmentedControl`.
///
/// This looks identical to the segmented `Picker` it replaces — on macOS,
/// SwiftUI's segmented picker *is* an `NSSegmentedControl`. It is written out
/// longhand for one reason: the toolbar has to size its item to the control,
/// and a control that reports its own intrinsic width cannot end up drawn
/// wider than the region that accepts clicks.
///
/// The reported fault was a click that visibly responded and changed nothing,
/// intermittently, with the window width deciding whether it worked. That is
/// the signature of content wider than its toolbar item: the segments are all
/// visible, but only the part inside the item's bounds receives the click.
/// Notes is leftmost and is usually the section already showing, so it appears
/// to work while Roadmap and Connections do nothing.
///
/// An `NSViewRepresentable` gives the toolbar an `NSView` with a real
/// intrinsic content size and its own hit testing, so what is drawn is what
/// responds.
struct SectionSegmentedControl: NSViewRepresentable {
    @Binding var selection: WorkspaceSession.WorkspaceSection
    var isEnabled: Bool = true

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = SectionSwitcherSegmentedControl(
            labels: context.coordinator.labels,
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.segmentChanged(_:))
        )
        control.segmentStyle = .rounded
        control.selectedSegment = context.coordinator.index(of: selection)
        control.isEnabled = isEnabled
        control.controlSize = .regular
        control.equalizeSegmentWidths(labelPadding: sectionSwitcherLabelPadding)
        // Refuse to be squeezed: a compressed control is a control whose
        // segments no longer sit under the pointer.
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        control.setAccessibilityLabel("Workspace section")
        control.toolTip = context.coordinator.toolTip(isEnabled: isEnabled)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        let index = context.coordinator.index(of: selection)
        if control.selectedSegment != index { control.selectedSegment = index }
        if control.isEnabled != isEnabled { control.isEnabled = isEnabled }
        let toolTip = context.coordinator.toolTip(isEnabled: isEnabled)
        if control.toolTip != toolTip { control.toolTip = toolTip }
        (control as? SectionSwitcherSegmentedControl)?
            .equalizeSegmentWidths(labelPadding: sectionSwitcherLabelPadding)
    }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<WorkspaceSession.WorkspaceSection>
        private let sections = WorkspaceSession.WorkspaceSection.allCases

        init(selection: Binding<WorkspaceSession.WorkspaceSection>) {
            self.selection = selection
        }

        var labels: [String] { sections.map { title(for: $0) } }

        // Written with explicit returns rather than switch-expression arms.
        // Switch expressions are valid here, but this file cannot be compiled
        // in the environment it was written in, and a build failure costs the
        // reader a round trip while three `return` keywords cost nothing.
        func title(for section: WorkspaceSession.WorkspaceSection) -> String {
            switch section {
            case .notes: return "Notes"
            case .roadmap: return "Roadmap"
            case .connections: return "Connections"
            }
        }

        func index(of section: WorkspaceSession.WorkspaceSection) -> Int {
            sections.firstIndex(of: section) ?? 0
        }

        /// The control is disabled until a project is open. Saying why is the
        /// difference between a control that is broken and one that is waiting.
        func toolTip(isEnabled: Bool) -> String {
            isEnabled
                ? "Switch between Notes, Roadmap and Connections"
                : "Open a project to switch sections"
        }

        @objc func segmentChanged(_ sender: NSSegmentedControl) {
            let index = sender.selectedSegment
            guard sections.indices.contains(index) else { return }
            let chosen = sections[index]
            // The control moves its own highlight before this runs. Writing the
            // selection only when it actually differs keeps the binding's side
            // effects (building the graph, loading the roadmap) to real changes
            // rather than to every click on the current section.
            guard selection.wrappedValue != chosen else { return }
            selection.wrappedValue = chosen
        }
    }
}
