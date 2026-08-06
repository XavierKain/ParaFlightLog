//
//  PostFlightConditionView.swift
//  ParaFlightLogWatch Watch App
//
//  The one question worth asking once a flight is saved: how was it?
//
//  A report page you have to remember to visit gets forgotten. Asked here it
//  costs one tap, and it is the only moment the pilot actually KNOWS the
//  answer — before launching they were guessing from the windsock.
//
//  Two things make this report better than the pre-flight one:
//  it is filed against the TAKEOFF coordinates (the landing field is often
//  outside the 1.5 km the iPhone searches, and is not what other pilots are
//  asking about), and its wording follows the kind of flying that was done —
//  "working well" means nothing to a soaring pilot, "moderate wind" means
//  nothing to a thermal one.
//
//  Target: Watch only
//

import SwiftUI

struct PostFlightConditionView: View {
    /// Drives the wording of the question and of every choice.
    let flightType: FlightType
    /// Where the flight STARTED. Nil when the flight was recorded without a
    /// fix, in which case there is nothing to report against and the view is
    /// never shown (see FlightSummaryView).
    let takeoffLatitude: Double
    let takeoffLongitude: Double
    /// Called when the pilot answers or skips — the summary closes either way.
    let onFinish: () -> Void

    @Environment(WatchConnectivityManager.self) private var watchManager

    @State private var isSending = false
    @State private var result: ConditionReportResult?

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                if let result {
                    outcome(result)
                } else if isSending {
                    ProgressView()
                        .padding(.vertical, 20)
                } else {
                    question
                }
            }
            .padding(.horizontal, 2)
        }
    }

    // MARK: - The question

    private var question: some View {
        VStack(spacing: 8) {
            Text(ConditionVocabulary.postFlightQuestion(for: flightType))
                .font(.headline)
                .multilineTextAlignment(.center)
                .padding(.top, -6)

            Text("Shared with pilots watching this spot.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            ForEach(ConditionVocabulary.postFlightForces) { force in
                Button {
                    send(force)
                } label: {
                    Text(ConditionVocabulary.label(force, for: flightType))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }

            Button("Skip", action: onFinish)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.caption)
                .padding(.top, 2)
        }
    }

    // MARK: - The verdict, straight from the iPhone

    @ViewBuilder
    private func outcome(_ result: ConditionReportResult) -> some View {
        VStack(spacing: 8) {
            Image(systemName: result.outcome == .posted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(result.outcome == .posted ? .green : .orange)

            Text(message(for: result))
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(result.outcome == .posted ? .primary : .secondary)

            Button("Done", action: onFinish)
                .buttonStyle(.bordered)
                .padding(.top, 2)
        }
        .padding(.top, 8)
    }

    /// The Watch never decides anything here — the iPhone owns auth, the spot
    /// list and the network, so its verdict is shown as-is.
    private func message(for result: ConditionReportResult) -> String {
        switch result.outcome {
        case .posted:
            if let spot = result.spotName {
                return String(localized: "Thanks! Shared for \(spot).")
            }
            return String(localized: "Thanks! Your report was shared.")
        case .notSignedIn:
            return String(localized: "Sign in on your iPhone to share reports.")
        case .noSpotNearby:
            return String(localized: "No known spot at your takeoff, so there was nowhere to file this.")
        case .noLocation:
            return String(localized: "No GPS fix was recorded at takeoff.")
        case .backendUnavailable:
            return String(localized: "Community reports are not available yet.")
        case .phoneUnreachable:
            return String(localized: "Your iPhone was out of reach, so nothing was sent.")
        case .cooldown, .sendFailed, .failed:
            return String(localized: "Your report could not be sent.")
        }
    }

    // MARK: - Sending

    private func send(_ force: WindForce) {
        isSending = true
        watchManager.submitConditionReport(
            status: ConditionVocabulary.impliedStatus(for: force),
            windForce: force,
            latitude: takeoffLatitude,
            longitude: takeoffLongitude,
            postFlight: true
        ) { outcome in
            isSending = false
            result = outcome
        }
    }
}
