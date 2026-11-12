import JitsiCore
import JitsiUI
import SwiftUI
import UIKit

/// Participant roster with the moderator controls the server enforces: mute a remote
/// microphone and remove a participant. Both are no-ops for anyone but moderators.
struct DemoParticipantsPane: View {
    @ObservedObject var model: MeetingSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List(model.tiles) { tile in
                HStack(spacing: 12) {
                    ParticipantAvatar(name: tile.displayName, url: tile.avatarURL, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(tile.displayName)
                                .lineLimit(1)
                            if tile.isModerator {
                                Image(systemName: "crown.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                        }
                        HStack(spacing: 6) {
                            Text(tile.isLocal ? "You" : tile.role.rawValue.capitalized)
                            if tile.audioMuted {
                                Image(systemName: "mic.slash.fill")
                                    .foregroundStyle(.red)
                            }
                            if tile.raisedHand {
                                Image(systemName: "hand.raised.fill")
                                    .foregroundStyle(.yellow)
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        if let email = tile.email, !email.isEmpty {
                            Text(email)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    if !tile.isLocal {
                        Menu {
                            Button {
                                model.muteParticipant(tile.id, mediaType: .audio)
                            } label: {
                                Label("Mute microphone", systemImage: "mic.slash")
                            }
                            if model.isModerator {
                                Button(role: .destructive) {
                                    model.kick(tile.id)
                                } label: {
                                    Label("Remove from meeting", systemImage: "person.badge.minus")
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.title3)
                        }
                        .accessibilityLabel("Actions for \(tile.displayName)")
                    }
                }
            }
            .navigationTitle("Participants")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// Polls roster. Creation needs a moderator and the Prosody polls component; voting is
/// open to everyone. Results are tallies because the component sends answers anonymously.
struct DemoPollsPane: View {
    @ObservedObject var model: MeetingSession
    @Environment(\.dismiss) private var dismiss

    @State private var question = ""
    @State private var answers = ["", ""]

    var body: some View {
        NavigationView {
            List {
                if !model.pollsSupported {
                    Section {
                        Text("Polls are not enabled on this deployment — the Prosody polls component is missing.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if !model.polls.isEmpty {
                    Section("Active polls") {
                        ForEach(model.polls) { poll in
                            DemoPollRow(poll: poll) { selections in
                                model.answerPoll(poll.id, selections: selections)
                            }
                        }
                    }
                }

                if model.pollsSupported, model.isModerator {
                    Section("New poll") {
                        TextField("Question", text: $question)
                            .textInputAutocapitalization(.sentences)
                        ForEach(answers.indices, id: \.self) { index in
                            TextField("Answer \(index + 1)", text: $answers[index])
                        }
                        Button("Add answer") { answers.append("") }
                            .disabled(answers.count >= 6)
                        Button("Create poll") { createPoll() }
                            .disabled(!canCreate)
                    }
                }
            }
            .navigationTitle("Polls")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var canCreate: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && answers.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count >= 2
    }

    private func createPoll() {
        model.createPoll(question: question, answers: answers)
        question = ""
        answers = ["", ""]
    }
}

private struct DemoPollRow: View {
    let poll: MeetingSession.Poll
    var vote: ([Bool]) -> Void

    @State private var selected: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(poll.question)
                .font(.headline)
            if poll.isHistory {
                Text("From earlier in the meeting")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            ForEach(poll.answers.indices, id: \.self) { index in
                Button {
                    guard !poll.hasAnswered else { return }
                    if selected.contains(index) {
                        selected.remove(index)
                    } else {
                        selected.insert(index)
                    }
                } label: {
                    HStack {
                        Image(systemName: selected.contains(index) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected.contains(index) ? Color.accentColor : .secondary)
                        Text(poll.answers[index])
                        Spacer()
                        Text("\(poll.counts.indices.contains(index) ? poll.counts[index] : 0)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }

            if !poll.hasAnswered {
                Button("Vote") {
                    var votes = Array(repeating: false, count: poll.answers.count)
                    for index in selected where votes.indices.contains(index) {
                        votes[index] = true
                    }
                    vote(votes)
                }
                .disabled(selected.isEmpty)
            } else {
                Text("Your vote was sent")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Rolling caption strip: the newest lines, with interim text dimmed until the engine
/// finalizes it.
struct DemoCaptionsOverlay: View {
    let captions: [MeetingSession.Caption]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(captions.suffix(3)) { caption in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(caption.speaker)
                        .fontWeight(.semibold)
                        .foregroundStyle(.yellow)
                    Text(caption.text)
                        .opacity(caption.isInterim ? 0.65 : 1)
                }
                .font(.footnote)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 16)
    }
}

/// Share sheet for the room URL.
struct DemoShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
