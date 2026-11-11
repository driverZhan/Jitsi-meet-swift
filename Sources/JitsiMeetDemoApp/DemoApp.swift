import JitsiMeetSDK
#if canImport(JitsiMeetExample)
import JitsiMeetExample
#endif
import SwiftUI

@main
struct DemoApp: App {
    var body: some Scene {
        WindowGroup {
            JoinView()
        }
    }
}

/// The host app is one form: point it at your deployment, then the custom screen takes over.
struct JoinView: View {
    // A device run restarts the app constantly, so the server and room survive relaunches.
    @AppStorage("demoHost") private var host = JitsiMeetDemo.defaultHost
    @AppStorage("demoDomain") private var domain = JitsiMeetDemo.defaultDomain
    @AppStorage("demoMuc") private var muc = JitsiMeetDemo.defaultMuc
    // v2: earlier builds persisted the old key; it is deliberately abandoned instead of
    // silently overriding the default, so a stale choice cannot pin the new deployment.
    @AppStorage("demoTransportV2") private var transport = JitsiMeetDemo.defaultTransport.rawValue
    @AppStorage("demoRoom") private var room = JitsiMeetDemo.defaultRoom
    @AppStorage("demoDisplayName") private var displayName = "Swift Guest"
    @AppStorage("demoEmail") private var email = ""
    @AppStorage("demoAvatarURL") private var avatarURL = ""
    @AppStorage("demoPassword") private var password = ""
    @AppStorage("demoAutoJoin") private var autoJoin = false
    @AppStorage("demoDebugSignaling") private var debugSignaling = false
    @State private var region: SDKConfig.Region = .international
    @State private var inMeeting = false
    @State private var busy = false
    @State private var status: String?

    var body: some View {
        ZStack(alignment: .top) {
            Color(.systemGroupedBackground).ignoresSafeArea()

            Form {
                Section(header: Text("Server")) {
                    TextField("Host or https://host:port", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("XMPP domain", text: $domain)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("MUC domain", text: $muc)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker("Transport", selection: $transport) {
                        Text("BOSH (/http-bind)").tag(ServerAddress.Transport.bosh.rawValue)
                        Text("WebSocket (/xmpp-websocket)").tag(ServerAddress.Transport.websocket.rawValue)
                    }
                    Picker("Region", selection: $region) {
                        Text("International").tag(SDKConfig.Region.international)
                        Text("China mainland").tag(SDKConfig.Region.chinaMainland)
                    }
                    Text(JitsiMeetDemo.callPresentationSummary(for: region))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section(header: Text("Conference")) {
                    TextField("Room", text: $room)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Display name", text: $displayName)
                    TextField("Email (optional)", text: $email)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)
                    TextField("Avatar URL (optional)", text: $avatarURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("Room password (optional)", text: $password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section {
                    Toggle("Auto join on launch", isOn: $autoJoin)
                    Toggle("Debug signaling logs", isOn: $debugSignaling)
                    Button(action: join) {
                        if busy {
                            ProgressView()
                        } else {
                            Text("Join meeting")
                        }
                    }
                    .disabled(busy || host.isEmpty || room.isEmpty)
                } footer: {
                    Text("Installs the JavaScriptCore runtime and the vendored libwebrtc backend, "
                         + "then opens the custom demo screen. Debug tracing logs every BOSH/WebSocket "
                         + "frame and XMPP stanza, including the JWT and SASL payloads.")
                        .font(.footnote)
                }
            }

            if let status {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(Color.red, in: Capsule())
                    .padding(.top, 60)
            }
        }
        .fullScreenCover(isPresented: $inMeeting) {
            DemoMeetingScreen(
                connection: JitsiMeetDemo.connection(
                    host: host,
                    transport: selectedTransport,
                    domain: domain,
                    muc: muc
                ),
                conference: JitsiMeetDemo.conference(
                    room: room,
                    displayName: displayName,
                    email: email.isEmpty ? nil : email,
                    avatarURL: avatarURL.isEmpty ? nil : avatarURL,
                    password: password.isEmpty ? nil : password
                ),
                onEnded: { inMeeting = false }
            )
        }
        // Two ways to skip the tap: the env key lets `SIMCTL_CHILD_JITSI_DEMO_AUTOJOIN=1 xcrun
        // simctl launch` drive straight into the screen for captures, and the toggle above is
        // what a real device uses, where attaching a debugger means relaunching the app.
        .task {
            // Replace only the old placeholder; a server the user typed is left alone.
            if host == "meet.example.org" {
                host = JitsiMeetDemo.defaultHost
            }
            // The default deployment moved from the self-hosted server to meet.jit.si, and
            // @AppStorage keeps the old values across launches; migrate exactly those.
            if host == "https://tmeeting.maesgroup.com:8443" || host == "tmeeting.maesgroup.com:8443" {
                host = JitsiMeetDemo.defaultHost
                domain = JitsiMeetDemo.defaultDomain
                muc = JitsiMeetDemo.defaultMuc
            }
            if room == "jitsi-swift-demo" {
                room = JitsiMeetDemo.defaultRoom
            }
            // Persisted @AppStorage lives in the app container, which `simctl spawn defaults`
            // no longer reaches on current runtimes; these overrides make launches scriptable.
            let environment = ProcessInfo.processInfo.environment
            if let value = environment["JITSI_DEMO_HOST"], !value.isEmpty {
                host = value
            }
            if let value = environment["JITSI_DEMO_DOMAIN"], !value.isEmpty {
                domain = value
            }
            if let value = environment["JITSI_DEMO_MUC"], !value.isEmpty {
                muc = value
            }
            if let value = environment["JITSI_DEMO_TRANSPORT"],
               ServerAddress.Transport(rawValue: value) != nil {
                transport = value
            }
            if let value = environment["JITSI_DEMO_ROOM"], !value.isEmpty {
                room = value
            }
            if let value = environment["JITSI_DEMO_NAME"], !value.isEmpty {
                displayName = value
            }
            if let value = environment["JITSI_DEMO_PASSWORD"], !value.isEmpty {
                password = value
            }
            if environment.keys.contains("JITSI_DEMO_DEBUG") {
                debugSignaling = true
            }
            if autoJoin || environment.keys.contains("JITSI_DEMO_AUTOJOIN") {
                join()
            }
        }
    }

    private var selectedTransport: ServerAddress.Transport {
        ServerAddress.Transport(rawValue: transport) ?? JitsiMeetDemo.defaultTransport
    }

    private func join() {
        busy = true
        status = nil
        Task {
            do {
                try await JitsiMeetDemo.bootstrap(
                    host: host,
                    region: region,
                    debugSignaling: debugSignaling
                )
                inMeeting = true
            } catch {
                status = error.localizedDescription
            }
            busy = false
        }
    }
}
