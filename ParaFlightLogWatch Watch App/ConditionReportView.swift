//
//  ConditionReportView.swift
//  ParaFlightLogWatch Watch App
//
//  Post a community CONDITION REPORT from the wrist, standing on the launch.
//  This is the point of the feature: a pilot about to fly will not take their
//  phone out, and most spots have no wind beacon — the report IS the beacon.
//
//  Two taps (status, wind) plus Send. The Watch knows nothing about spots,
//  auth or cooldowns, so it sends raw coordinates to the iPhone and shows the
//  answer it gets back, verbatim. It never claims a success it did not get,
//  and it never queues a report for later: a condition report expires after
//  3 h server-side, so a late one describes weather that is gone.
//  Target: Watch only
//

import SwiftUI

struct ConditionReportView: View {
    @Environment(WatchConnectivityManager.self) private var watchManager
    @Environment(WatchLocationService.self) private var locationService

    /// Nothing is preselected: a default would be a guess put in the pilot's
    /// mouth, and other pilots act on this.
    @State private var status: ReportStatus?
    @State private var windForce: WindForce?
    @State private var phase: Phase = .form

    /// The screen is one of three things at a time.
    private enum Phase {
        case form
        case sending
        case done(ConditionReportResult)
    }

    var body: some View {
        ScrollView {
            switch phase {
            case .form:
                formContent
            case .sending:
                sendingContent
            case .done(let result):
                resultContent(result)
            }
        }
        .onAppear {
            // Idempotent — makes sure a fix is on its way even if the pilot
            // came straight here after launching the app.
            locationService.startUpdatingLocation()
        }
    }

    // MARK: - Form

    private var formContent: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .foregroundStyle(.blue)
                Text("Conditions")
                    .font(.headline)
            }
            .padding(.top, 4)

            HStack(spacing: 4) {
                Image(systemName: "location.fill")
                    .font(.caption2)
                    .foregroundStyle(.blue)
                Text(locationService.currentSpotName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            sectionLabel("Status")

            ForEach(ReportStatus.allCases) { option in
                Button {
                    status = option
                } label: {
                    HStack(spacing: 8) {
                        Text(option.emoji)
                            .font(.system(size: 18))
                            .frame(width: 26)
                        Text(option.label)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Spacer(minLength: 0)
                        if status == option {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                    .padding(.vertical, 7)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(status == option ? Color.green.opacity(0.18) : Color.gray.opacity(0.15))
                    )
                }
                .buttonStyle(.plain)
            }

            sectionLabel("Wind")

            ForEach(WindForce.allCases) { option in
                Button {
                    windForce = option
                } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(option.label)
                                .font(.body)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            // Knots, not km/h: the iPhone's wind-unit
                            // preference is not synced to the Watch.
                            Text(option.knotsHint)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if windForce == option {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(windForce == option ? Color.green.opacity(0.18) : Color.gray.opacity(0.15))
                    )
                }
                .buttonStyle(.plain)
            }

            Button {
                send()
            } label: {
                Label("Send", systemImage: "paperplane.fill")
                    .font(.body)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(status == nil || windForce == nil)
            .padding(.top, 2)
            .padding(.bottom, 6)
        }
        .padding(.horizontal, 6)
    }

    @ViewBuilder
    private func sectionLabel(_ text: String) -> some View {
        HStack {
            Text(text)
                .font(.caption2)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.leading, 4)
        .padding(.top, 2)
    }

    // MARK: - Sending

    private var sendingContent: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Sending…")
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    // MARK: - Result

    @ViewBuilder
    private func resultContent(_ result: ConditionReportResult) -> some View {
        VStack(spacing: 10) {
            Image(systemName: result.outcome.symbolName)
                .font(.system(size: 34))
                .foregroundStyle(result.outcome.tint)
                .padding(.top, 12)

            Text(message(for: result))
                .font(.body)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.8)

            Button(result.outcome == .posted ? "Done" : "Back") {
                if result.outcome == .posted {
                    // Clear the selection so the next report is a fresh,
                    // deliberate one rather than a stale repeat.
                    status = nil
                    windForce = nil
                }
                phase = .form
            }
            .buttonStyle(.bordered)
            .padding(.bottom, 8)
        }
        .padding(.horizontal, 8)
    }

    /// The exact sentence the pilot reads. Honest in every branch: nothing
    /// here says "sent" unless the iPhone confirmed the row was created.
    private func message(for result: ConditionReportResult) -> String {
        switch result.outcome {
        case .posted:
            if let spotName = result.spotName, !spotName.isEmpty {
                return "Reported at \(spotName). Thanks!"
            }
            return "Conditions reported. Thanks!"
        case .notSignedIn:
            return "Sign in on your phone first."
        case .cooldown:
            let minutes = max(1, Int((result.cooldownRemaining / 60).rounded(.up)))
            return "You already reported here — try again in \(minutes) min."
        case .noSpotNearby:
            return "No known spot within 1.5 km."
        case .backendUnavailable:
            return "Reports aren't available yet. Try again later."
        case .failed:
            return "Report failed. Nothing was posted."
        case .phoneUnreachable:
            return "iPhone not reachable. Nothing was sent."
        case .sendFailed:
            return "The iPhone didn't answer. Check the app before reporting again."
        case .noLocation:
            return "No GPS fix yet. Wait a moment and try again."
        }
    }

    // MARK: - Send

    private func send() {
        guard let status, let windForce else { return }

        guard let location = locationService.lastKnownLocation else {
            phase = .done(ConditionReportResult(outcome: .noLocation))
            return
        }

        phase = .sending
        watchManager.submitConditionReport(
            status: status,
            windForce: windForce,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude
        ) { result in
            self.phase = .done(result)
        }
    }
}

// MARK: - Outcome presentation (Watch-only)

private extension ConditionReportOutcome {
    /// Icon shown on the result screen.
    var symbolName: String {
        switch self {
        case .posted: return "checkmark.circle.fill"
        case .notSignedIn: return "person.crop.circle.badge.exclamationmark"
        case .cooldown: return "clock.fill"
        case .noSpotNearby: return "mappin.slash"
        case .backendUnavailable: return "icloud.slash"
        case .failed: return "exclamationmark.triangle.fill"
        case .phoneUnreachable: return "iphone.slash"
        case .sendFailed: return "questionmark.circle.fill"
        case .noLocation: return "location.slash"
        }
    }

    /// Green only for a confirmed post — every other state is a warning.
    var tint: Color {
        switch self {
        case .posted: return .green
        case .cooldown, .noSpotNearby, .noLocation, .sendFailed: return .orange
        case .notSignedIn, .backendUnavailable, .failed, .phoneUnreachable: return .red
        }
    }
}
