//
//  ConditionReportViews.swift
//  ParaFlightLog
//
//  Condition-report UI (Phase 3 of the community loop):
//  - ConditionReportSheet: the 2-tap "report conditions" flow (status chip +
//    wind-force chip → submit), with a pre-filled 8-point compass dial, wing
//    size and optional note. Signed-out shows a friendly prompt.
//  - SpotReportsSection: a List section for spot pages — consensus banner,
//    recent reports, a "Report conditions" button and a "Follow this spot"
//    bell toggle.
//
//  Everything is fail-soft: when the backend isn't configured the section
//  renders nothing at all (same pattern as SpotCommunitySection).
//  Target: iOS only
//

import SwiftUI
import Foundation // cos/sin for the compass dial layout
import Combine // 1-second timer for the submit-cooldown countdown

// MARK: - ConditionReportSheet (the 2-tap flow)

struct ConditionReportSheet: View {
    @Environment(\.dismiss) private var dismiss
    // Optional: a sheet doesn't always inherit a custom @Observable environment
    // object, so read it fail-soft rather than trapping on a missing injection.
    @Environment(DataController.self) private var dataController: DataController?

    /// The spot being reported on (optional — Explore/derived-key callers may
    /// not have a local Spot). Coordinates, when present, pre-fill the dial.
    let spot: Spot?
    let spotKey: String
    let spotName: String

    @State private var status: ReportStatus?
    @State private var windForce: WindForce?
    /// Selected wind direction (degrees, wind comes FROM). Pre-filled from the
    /// spot's current Open-Meteo forecast; nil until then / when unavailable.
    @State private var windDirectionDeg: Double?
    @State private var wingSize: String = ""
    @State private var note: String = ""

    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var didPrefillDirection = false

    /// Remaining anti-spam cooldown for this spot (0 = free to post). Seeded on
    /// appear and ticked down while the sheet is open.
    @State private var cooldownRemaining: TimeInterval = 0
    private let cooldownTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var isSignedIn: Bool { AuthService.shared.state.isSignedIn }
    private var canSubmit: Bool {
        status != nil && windForce != nil && !isSubmitting && cooldownRemaining <= 0
    }

    var body: some View {
        NavigationStack {
            Group {
                if isSignedIn {
                    form
                } else {
                    signedOutPrompt
                }
            }
            .navigationTitle("Report conditions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if isSignedIn {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Post") { Task { await submit() } }
                            .disabled(!canSubmit)
                    }
                }
            }
        }
    }

    // MARK: Form

    private var form: some View {
        Form {
            Section {
                Text(spotName)
                    .font(.headline)
            }

            // 1) Status — one tap.
            Section {
                ChipGrid(items: ReportStatus.allCases, selection: $status) { item, selected in
                    StatusChip(status: item, isSelected: selected)
                }
            } header: {
                Text("How is it?")
            }

            // 2) Wind force — one tap. Submit enables here.
            Section {
                ChipGrid(items: WindForce.allCases, selection: $windForce) { item, selected in
                    ForceChip(force: item, isSelected: selected)
                }
            } header: {
                Text("Wind strength")
            }

            // Direction — pre-filled from the forecast, tap to change.
            Section {
                CompassDial(selectionDeg: $windDirectionDeg)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            } header: {
                Text("Wind direction")
            } footer: {
                Text(didPrefillDirection
                     ? "Pre-filled from the current forecast — tap a point to change."
                     : "Tap the point the wind comes from.")
            }

            // Wing size — pre-filled from the default wing.
            Section {
                TextField("Wing size (e.g. 22)", text: $wingSize)
                    .textInputAutocapitalization(.characters)
            } header: {
                Text("Wing size")
            }

            // Optional note.
            Section {
                TextField("Add a note (optional)", text: $note, axis: .vertical)
                    .lineLimit(1...3)
            } header: {
                Text("Note")
            }

            if cooldownRemaining > 0 {
                Section {
                    Label(cooldownHint, systemImage: "clock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .task {
            await prefill()
            // Check the anti-spam cooldown when the sheet appears.
            cooldownRemaining = ConditionReportService.shared.submitCooldownRemaining(forSpotKey: spotKey)
        }
        .onReceive(cooldownTimer) { _ in
            guard cooldownRemaining > 0 else { return }
            cooldownRemaining = ConditionReportService.shared.submitCooldownRemaining(forSpotKey: spotKey)
        }
    }

    /// "post again in N min" hint shown while the spot is in cooldown.
    private var cooldownHint: String {
        let minutes = Int(ceil(cooldownRemaining / 60))
        if minutes <= 1 {
            return "You reported here recently — you can post again in under a minute."
        }
        return "You reported here recently — you can post again in \(minutes) min."
    }

    // MARK: Signed-out prompt

    private var signedOutPrompt: some View {
        ContentUnavailableView {
            Label("Sign in to report", systemImage: "person.crop.circle.badge.questionmark")
        } description: {
            Text("Condition reports are tied to your pilot account. Sign in from Settings › Account to share how it flies right now.")
        }
    }

    // MARK: Actions

    /// Best-effort pre-fill: wing size from the default wing, wind direction
    /// from the spot's current forecast. Never blocks the form.
    private func prefill() async {
        // Wing size from the last-used wing (same source as AddFlightView).
        if wingSize.isEmpty,
           let idString = UserDefaults.standard.string(forKey: UserDefaultsKeys.lastUsedWingId),
           let id = UUID(uuidString: idString),
           let size = dataController?.findWing(byId: id)?.size,
           !size.isEmpty {
            wingSize = size
        }

        // Wind direction from the spot's current Open-Meteo forecast.
        guard windDirectionDeg == nil,
              let latitude = spot?.latitude,
              let longitude = spot?.longitude else { return }
        do {
            let weather = try await WeatherService.shared.weather(latitude: latitude, longitude: longitude)
            if let direction = weather.windDirectionDeg, windDirectionDeg == nil {
                // Snap to the nearest 8-point so the dial reads cleanly.
                windDirectionDeg = WeatherService.compassToDegrees(WeatherService.degreesToCompass(direction))
                didPrefillDirection = true
            }
        } catch {
            // No forecast: the pilot picks the direction manually.
        }
    }

    private func submit() async {
        guard let status, let windForce else { return }
        isSubmitting = true
        errorMessage = nil
        do {
            try await ConditionReportService.shared.submitReport(
                spot: spot,
                spotKey: spotKey,
                spotName: spotName,
                status: status,
                windForce: windForce,
                windDirectionDeg: windDirectionDeg,
                wingSize: wingSize.isEmpty ? nil : wingSize,
                note: note.isEmpty ? nil : note
            )
            // Posting a report is a good moment to line up push (fail-soft in
            // the push layer if APNs isn't configured). Fire-and-forget so it
            // never delays the dismiss.
            Task { await PushService.shared.ensureAuthorized() }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Could not post your report."
            // Sync the cooldown state (e.g. a just-started cooldown blocked this).
            cooldownRemaining = ConditionReportService.shared.submitCooldownRemaining(forSpotKey: spotKey)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
        isSubmitting = false
    }
}

// MARK: - SpotReportsSection (spot page)

/// Condition reports for one spot, as a List section: consensus banner,
/// recent reports, a "Report conditions" button and a follow toggle. Hides
/// itself silently when the backend isn't configured.
struct SpotReportsSection: View {
    let spot: Spot?
    let spotKey: String
    let spotName: String

    private enum LoadState {
        case loading
        case loaded([SpotReport])
        case failed
        /// Backend not configured: render nothing at all.
        case hidden
    }

    @State private var state: LoadState = .loading
    @State private var showingReportSheet = false
    @State private var isSubscribed = false
    @State private var isTogglingFollow = false

    private var isSignedIn: Bool { AuthService.shared.state.isSignedIn }

    var body: some View {
        switch state {
        case .hidden:
            EmptyView()
        default:
            section
        }
    }

    private var section: some View {
        Section {
            switch state {
            case .loading:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading reports…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .failed:
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text("Could not load reports.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Retry") { Task { await load(forceRefresh: true) } }
                        .font(.caption)
                        .buttonStyle(.borderless)
                }
            case .loaded(let reports):
                loadedRows(reports)
            case .hidden:
                EmptyView()
            }

            reportButton
        } header: {
            HStack {
                Text("Conditions now")
                Spacer()
                if isSignedIn {
                    followButton
                }
            }
            // Attached to the header (a plain view), not the Section.
            .task { await onAppear() }
        } footer: {
            if case .loaded = state {
                Text("Crowd-sourced reports from pilots, valid for 3 hours.")
            }
        }
        .sheet(isPresented: $showingReportSheet, onDismiss: { Task { await load(forceRefresh: true) } }) {
            ConditionReportSheet(spot: spot, spotKey: spotKey, spotName: spotName)
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func loadedRows(_ reports: [SpotReport]) -> some View {
        if let consensus = reports.consensus {
            ConsensusBanner(consensus: consensus)
            ForEach(reports) { report in
                ReportRow(report: report)
            }
        } else {
            Text("No reports yet — be the first to say how it flies.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var reportButton: some View {
        Button {
            showingReportSheet = true
        } label: {
            Label("Report conditions", systemImage: "megaphone.fill")
        }
    }

    private var followButton: some View {
        Button {
            Task { await toggleFollow() }
        } label: {
            Image(systemName: isSubscribed ? "bell.fill" : "bell")
                .font(.caption)
                .foregroundStyle(isSubscribed ? .blue : .secondary)
        }
        .buttonStyle(.borderless)
        .disabled(isTogglingFollow)
        .accessibilityLabel(isSubscribed ? "Unfollow this spot" : "Follow this spot")
    }

    // MARK: Loading

    private func onAppear() async {
        await load(forceRefresh: false)
        if isSignedIn {
            isSubscribed = await ConditionReportService.shared.isSubscribed(spotKey: spotKey)
        }
    }

    private func load(forceRefresh: Bool) async {
        if case .loaded = state {} else { state = .loading }
        do {
            let reports = try await ConditionReportService.shared.recentReports(
                forSpotKey: spotKey, forceRefresh: forceRefresh
            )
            state = .loaded(reports)
        } catch ConditionReportError.backendNotConfigured {
            state = .hidden
        } catch {
            if case .loaded = state {} else { state = .failed }
        }
    }

    private func toggleFollow() async {
        guard !isTogglingFollow else { return }
        isTogglingFollow = true
        let wasSubscribed = isSubscribed
        do {
            if wasSubscribed {
                try await ConditionReportService.shared.unsubscribe(spotKey: spotKey)
                isSubscribed = false
            } else {
                try await ConditionReportService.shared.subscribe(spotKey: spotKey, spotName: spotName)
                isSubscribed = true
                // Following implies wanting push — ask now (fail-soft downstream).
                await PushService.shared.ensureAuthorized()
            }
            UISelectionFeedbackGenerator().selectionChanged()
        } catch {
            // Leave the toggle as it was; the section keeps working.
            logWarning("Follow toggle failed for \(spotKey): \(error.localizedDescription)", category: .community)
        }
        isTogglingFollow = false
    }
}

// MARK: - Consensus banner

private struct ConsensusBanner: View {
    let consensus: ReportConsensus

    var body: some View {
        let report = consensus.latest
        HStack(spacing: 10) {
            Text(report.status.emoji)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(report.status.color)
                Text(subline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    /// "Flying now — SW moderate" style headline.
    private var headline: String {
        let report = consensus.latest
        var parts: [String] = [report.status.label]
        var conditions: [String] = []
        if let direction = report.windDirectionDeg {
            conditions.append(WeatherService.degreesToCompass(direction))
        }
        if let force = report.windForce {
            conditions.append(force.label.lowercased())
        }
        if !conditions.isEmpty {
            parts.append(conditions.joined(separator: " "))
        }
        return parts.joined(separator: " — ")
    }

    /// "12 min ago · 3 reports" style subline (plain String → manual plural).
    private var subline: String {
        let relative = consensus.latest.createdAt
            .formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
        let count = consensus.concurringCount
        let reports = "\(count) report\(count == 1 ? "" : "s")"
        return "\(relative) · \(reports)"
    }
}

// MARK: - Report row

private struct ReportRow: View {
    let report: SpotReport

    var body: some View {
        HStack(spacing: 10) {
            Text(report.status.emoji)
                .font(.body)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(report.pilotName)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text(report.status.label)
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .foregroundStyle(report.status.color)
                        .background(report.status.color.opacity(0.15))
                        .clipShape(Capsule())
                }
                HStack(spacing: 8) {
                    if let condition = conditionText {
                        Text(condition)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let note = report.note {
                        Text("“\(note)”")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            Text(report.createdAt, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    /// "SW · moderate" from the report's wind fields (either may be missing).
    private var conditionText: String? {
        var parts: [String] = []
        if let direction = report.windDirectionDeg {
            parts.append(WeatherService.degreesToCompass(direction))
        }
        if let force = report.windForce {
            parts.append(force.label.lowercased())
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Chips

/// Single-select grid of chips over `items`, tapping toggles `selection`.
private struct ChipGrid<Item: Identifiable & Equatable, Content: View>: View {
    let items: [Item]
    @Binding var selection: Item?
    @ViewBuilder let content: (Item, Bool) -> Content

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(items) { item in
                Button {
                    selection = item
                    UISelectionFeedbackGenerator().selectionChanged()
                } label: {
                    content(item, selection == item)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct StatusChip: View {
    let status: ReportStatus
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 4) {
            Text(status.emoji)
                .font(.title3)
            Text(status.label)
                .font(.caption2.weight(.medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(isSelected ? .white : .primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(isSelected ? status.color : Color(.tertiarySystemFill))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct ForceChip: View {
    let force: WindForce
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 2) {
            Text(force.label)
                .font(.caption.weight(.medium))
                .foregroundStyle(isSelected ? .white : .primary)
            Text("\(force.kmhHint) km/h")
                .font(.caption2)
                .foregroundStyle(isSelected ? Color.white.opacity(0.85) : .secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(isSelected ? Color.blue : Color(.tertiarySystemFill))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Compass dial (8-point, single select)

/// An 8-point compass dial. Tapping a point selects the direction the wind
/// comes FROM (0 = N, clockwise). The center arrow points along the flow.
private struct CompassDial: View {
    /// Bound direction in degrees (nil = none selected).
    @Binding var selectionDeg: Double?

    private let diameter: CGFloat = 180
    private let points = WeatherService.compassPoints // ["N","NE",...,"NW"]

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(.systemGray4), lineWidth: 1)
                .frame(width: diameter, height: diameter)

            // Center flow arrow (only when a direction is chosen).
            if let deg = selectionDeg {
                Image(systemName: "location.north.fill")
                    .font(.title2)
                    .foregroundStyle(.blue)
                    // Wind comes FROM `deg`; the arrow shows where it blows TO.
                    .rotationEffect(.degrees(deg + 180))
            } else {
                Image(systemName: "dot.scope")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
            }

            // The 8 tappable points around the ring.
            ForEach(Array(points.enumerated()), id: \.offset) { index, label in
                let degrees = Double(index) * 45
                let isSelected = selectionDeg.map { WeatherService.degreesToCompass($0) == label } ?? false
                Button {
                    selectionDeg = degrees
                    UISelectionFeedbackGenerator().selectionChanged()
                } label: {
                    Text(label)
                        .font(.caption.weight(isSelected ? .bold : .regular))
                        .foregroundStyle(isSelected ? .white : .primary)
                        .frame(width: 34, height: 26)
                        .background(isSelected ? Color.blue : Color(.tertiarySystemFill))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .offset(offset(forIndex: index))
            }
        }
        .frame(width: diameter + 40, height: diameter + 40)
    }

    /// Position of a compass point on the ring (N at top, clockwise).
    private func offset(forIndex index: Int) -> CGSize {
        let radius = diameter / 2
        let angle = Angle.degrees(Double(index) * 45 - 90).radians // -90 puts N at top
        return CGSize(width: cos(angle) * radius, height: sin(angle) * radius)
    }
}
