import SwiftUI

/// Dedicated settings surface keeps the library navigation and selection intact.
public struct SettingsWindowView: View {
    @ObservedObject var model: AppModel
    public init(model: AppModel) { self.model = model }
    public var body: some View {
        TabView {
            ForEach(SettingsPane.allCases) { pane in
                SettingsView(model: model, pane: pane)
                    .tabItem { Text(pane.rawValue) }
            }
        }
        .padding(.top, 12)
        .frame(minWidth: 580, idealWidth: 640, minHeight: 560, idealHeight: 720)
    }
}
