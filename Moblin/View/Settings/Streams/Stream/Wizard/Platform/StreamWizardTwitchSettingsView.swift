import SwiftUI

struct StreamWizardTwitchSettingsView: View {
    @EnvironmentObject private var model: Model

    var body: some View {
        Form {
            Section {
                TextField("MyChannel", text: $model.wizardTwitchChannelName)
                    .disableAutocorrection(true)
            } header: {
                Text("Channel name")
            }
            Section {
                TextField("908123903", text: $model.wizardTwitchChannelId)
                    .disableAutocorrection(true)
            } header: {
                Text("Channel id")
            } footer: {
                VStack(alignment: .leading) {
                    Text("Needed for channel chat emotes and number of viewers.")
                    Text("")
                    Text(
                        """
                        A large number. Use developer tools (F11) \
                        in your browser. Look at websocket messages. Hard to find.
                        """
                    )
                }
            }
            Section {
                NavigationLink(destination: StreamWizardNetworkSetupSettingsView(platform: "Twitch")) {
                    WizardNextButtonView()
                }
                .disabled(model.wizardTwitchChannelName.isEmpty)
            }
        }
        .onAppear {
            model.wizardPlatform = .twitch
        }
        .navigationTitle("Twitch")
        .toolbar {
            CreateStreamWizardToolbar()
        }
    }
}
