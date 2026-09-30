import SwiftUI
import AppKit

/// The Notes / Roadmap / Connections switcher, as a real `NSSegmentedControl`.
///
/// This looks identical to the segmented `Picker` it replaces — on macOS,
/// SwiftUI's segmented picker *is* an `NSSegmentedControl`. It is written out
/// longhand for one reason: the toolbar has to size its item to the control,
/// and a control that reports its own intrinsic width cannot end up drawn
/// wider than the region that accepts clicks.
///
/// The reported fault was a click on a segment that visibly responded and
/// changed nothing, intermittently, with the window width deciding whether it
/// worked. That is the signature of content wider than its toolbar item: the
/// segments are all visible, but only the part inside the item's bounds
/// receives the click. Notes is leftmost and is usually the section already
/// showing, so it appears to work while Roadmap and Connections do nothing.
///
/// An `NSViewRepresentable` gives the toolbar an `NSView` with a real
/// intrinsic content size and its own hit testing, so what is drawn is what
/// responds.
struct SectionSegmentedControl: NSViewRepresentable {
    @Binding var selection: WorkspaceSession.WorkspaceSection
    var isEnabled: Bool = true

    fileprivate static var sections: [WorkspaceSession.WorkspaceSection] {
        WorkspaceSession.WorkspaceSection.allCases
    }

    fileprivate static func title(for section: WorkspaceSession.WorkspaceSection) -> String {
        switch section {
        case .notes: "Notes"
        case .roadmap: "Roadmap"
        case .connections: "Connections"
        }
    }

    fileprivate static func index(of section: WorkspaceSession.WorkspaceSection) -> Int {
        sections.firstIndex(of: section) ?? 0
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: Self.sections.map { Self.title(for: $0) },
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.segmentChanged(_:))
        )
        control.segmentStyle = .rounded
        control.selectedSegment = Self.index(of: selection)
        control.isEnabled = isEnabled
        control.controlSize = .regular
        // Refuse to be squeezed: a compressed control is a control whose
        // segments no longer sit under the pointer.
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        control.setAccessibilityLabel("Workspace section")
        control.toolTip = "Switch between Notes, Roadmap and Connections"
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        let index = Self.index(of: selection)
        if control.selectedSegment != index { control.selectedSegment = index }
        if control.isEnabled != isEnabled { control.isEnabled = isEnabled }
    }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<WorkspaceSession.WorkspaceSection>

        init(selection: Binding<WorkspaceSession.WorkspaceSection>) {
            self.selection = selection
        }

        @objc func segmentChanged(_ sender: NSSegmentedControl) {
            let sections = SectionSegmentedControl.sections
            let index = sender.selectedSegment
            guard sections.indices.contains(index) else { return }
            let chosen = sections[index]
            // The control moves its own highlight before this runs. Writing the
            // selection only when it actually differs keeps the binding's
            // side effects (building the graph, loading the roadmap) to real
            // changes rather than to every click on the current section.
            guard selection.wrappedValue != chosen else { return }
            selection.wrappedValue = chosen
        }
    }
}
