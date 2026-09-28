import SwiftUI
import FolioCore

struct FolioSettingsView: View {
    @Bindable var session: WorkspaceSession
    @AppStorage("editorPointSize") private var editorPointSize = EditorPreferences.defaultPointSize

    var body: some View {
        TabView {
            Form {
                Section("Writing") {
                    HStack {
                        Text("Editor text size")
                        Slider(value: $editorPointSize, in: EditorPreferences.allowedPointSizes, step: 1)
                            .frame(width: 180).accessibilityLabel("Editor text size")
                        Text("\(Int(EditorPreferences.clampedPointSize(editorPointSize))) pt").monospacedDigit()
                    }
                }
                Section("Resource profile") {
                    Picker("Profile", selection: Binding(get: { session.search.profile }, set: {
                        session.search.setProfile($0)
                        UserDefaults.standard.set($0.rawValue, forKey: "searchProfile")
                    })) {
                        ForEach(SearchProfile.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Text("Controls SQLite settings, capture budgets and voice duration/buffer limits. These caps are not measured total memory or battery guarantees.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Accessibility") {
                    Label("Contrast and motion follow macOS", systemImage: "accessibility")
                    Text("Folio respects Increase Contrast and Reduce Motion.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Development build") {
                    Text("Plain Markdown, recovery copies and search caches are not encrypted. Use test copies until the native Mac gates pass.")
                        .font(.caption).foregroundStyle(FolioStyle.gold)
                }
            }
            .formStyle(.grouped).tabItem { Label("General", systemImage: "slider.horizontal.3") }
            ShortcutSettingsView(preferences: session.shortcuts).tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .padding(14).frame(width: 610, height: 560)
        .onAppear { editorPointSize = EditorPreferences.clampedPointSize(editorPointSize) }
    }
}
