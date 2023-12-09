import SwiftUI

struct StreamObsSettingsView: View {
    @EnvironmentObject var model: Model
    var stream: SettingsStream

    func submitWebSocketUrl(value: String) {
        stream.obsWebSocketUrl = value
        model.store()
        if stream.enabled {
            model.obsWebSocketUrlUpdated()
        }
    }

    func submitWebSocketPassword(value: String) {
        stream.obsWebSocketPassword = value
        model.store()
        if stream.enabled {
            model.obsWebSocketPasswordUpdated()
        }
    }

    var body: some View {
        Form {
            Section {
                NavigationLink(destination: TextEditView(
                    title: String(localized: "WebSocket URL"),
                    value: stream.obsWebSocketUrl!,
                    onSubmit: submitWebSocketUrl,
                    footer: Text("For example wss://232.32.45.332:4567.")
                )) {
                    TextItemView(name: String(localized: "WebSocket URL"), value: stream.obsWebSocketUrl!)
                }
                NavigationLink(destination: TextEditView(
                    title: String(localized: "WebSocket password"),
                    value: stream.obsWebSocketPassword!,
                    onSubmit: submitWebSocketPassword
                )) {
                    TextItemView(
                        name: String(localized: "WebSocket password"),
                        value: stream.obsWebSocketPassword!
                    )
                }
            }
        }
        .navigationTitle("OBS")
        .toolbar {
            SettingsToolbar()
        }
    }
}
