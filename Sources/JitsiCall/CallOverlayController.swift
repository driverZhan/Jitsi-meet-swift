import Foundation
import JitsiCore
import SwiftUI
import UIKit

/// Ringing UI that lives in the app, because a mainland build has no system call UI to
/// borrow. It is a plain window above the app's own content, not a banner, so it can carry
/// the conference name and both buttons at full size.
@MainActor
public final class CallOverlayController {
    public private(set) var callID: String?

    private var window: UIWindow?

    public init() {}

    public func show(call: IncomingCall, onAnswer: @escaping () -> Void, onDecline: @escaping () -> Void) {
        callID = call.id
        let target = Self.hostScene()
        let surface = window ?? (target.map { UIWindow(windowScene: $0) } ?? UIWindow())
        window = surface
        surface.windowLevel = .alert + 1
        surface.rootViewController = UIHostingController(rootView: CallOverlayView(
            call: call,
            onAnswer: onAnswer,
            onDecline: onDecline
        ))
        surface.isHidden = false
        surface.makeKeyAndVisible()
    }

    public func hide() {
        callID = nil
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
    }

    /// Multi-scene apps (Stage Manager, iPad) have more than one window scene; ring on the
    /// active one and fall back to any scene, since a suspended app has none active.
    private static func hostScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
    }
}

public struct CallOverlayView: View {
    private let call: IncomingCall
    private var onAnswer: () -> Void
    private var onDecline: () -> Void

    public init(call: IncomingCall, onAnswer: @escaping () -> Void, onDecline: @escaping () -> Void) {
        self.call = call
        self.onAnswer = onAnswer
        self.onDecline = onDecline
    }

    public var body: some View {
        VStack(spacing: 26) {
            Spacer()

            if let avatarURL = call.avatarURL, let url = URL(string: avatarURL) {
                AsyncImage(url: url) { image in
                    image.resizable()
                } placeholder: {
                    Circle().fill(Color(white: 0.25))
                }
                .frame(width: 96, height: 96)
                .clipShape(Circle())
            } else {
                Image(systemName: "person.2.circle.fill")
                    .font(.system(size: 92))
                    .foregroundStyle(.white.opacity(0.85))
            }

            VStack(spacing: 6) {
                Text(call.callerName)
                    .font(.title2.weight(.semibold))
                Text("Inviting you to \(call.conference)")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)

            Spacer()

            HStack(alignment: .top, spacing: 48) {
                Button(action: onDecline) {
                    OverlayButtonContent(systemName: "phone.down.fill", title: "Decline", tint: .red)
                }
                .accessibilityLabel("Decline")

                Button(action: onAnswer) {
                    OverlayButtonContent(systemName: "phone.fill", title: "Answer", tint: .green)
                }
                .accessibilityLabel("Answer")
            }
            .padding(.bottom, 44)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.92))
        .foregroundStyle(.white)
    }
}

private struct OverlayButtonContent: View {
    let systemName: String
    let title: String
    let tint: Color

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemName)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 68, height: 68)
                .background(Circle().fill(tint))
            Text(title)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.8))
        }
    }
}
