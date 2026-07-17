//
//  SocialViews.swift
//  ParaFlightLog
//
//  Social loop UI (Phase 4 of the community loop):
//  - PilotProfileView: editable "my profile" (nil / own userId) or a public
//    profile (follow, counts, recent shared flights with kudos).
//  - CommunityFeedView: the feed of flights from pilots you follow.
//  - SpotLeaderboardSection: a fail-soft List section ranking pilots at one
//    spot over today / this week / all-time.
//  - KudosButton: reusable optimistic heart + count.
//
//  Everything backed by SocialService is fail-soft: an unconfigured backend
//  (or any load error on a secondary section) renders nothing / an empty
//  state rather than an error, mirroring CommunityService's pattern.
//  Target: iOS only
//

import SwiftUI
import SwiftData

// MARK: - Shared helpers

/// Current signed-in user's id, or nil when signed out.
private func currentUserId() -> String? {
    if case let .signedIn(userId, _) = AuthService.shared.state { return userId }
    return nil
}

/// "1h05" / "45 min" from a duration (or aggregate airtime) in seconds.
private func socialDurationText(_ seconds: Int) -> String {
    let hours = seconds / 3600
    let minutes = (seconds % 3600) / 60
    if hours > 0 {
        return minutes > 0 ? "\(hours)h\(String(format: "%02d", minutes))" : "\(hours)h"
    }
    return "\(minutes) min"
}

/// Flight-type capsule badge, matching the Explore SharedFlightRow style.
private struct SocialFlightTypeBadge: View {
    let type: FlightType

    var body: some View {
        Label(type.rawValue, systemImage: type.symbolName)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.indigo)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.indigo.opacity(0.12), in: Capsule())
    }
}

// MARK: - KudosButton

/// Reusable kudos control: heart + count with an optimistic toggle. The
/// network call runs in the background; on failure the UI reverts. Seeds its
/// local state from the FeedItem it's given.
struct KudosButton: View {
    let item: FeedItem

    @State private var kudoed: Bool
    @State private var count: Int
    @State private var isBusy = false

    init(item: FeedItem) {
        self.item = item
        _kudoed = State(initialValue: item.hasKudoed)
        _count = State(initialValue: item.kudosCount)
    }

    var body: some View {
        Button {
            toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: kudoed ? "heart.fill" : "heart")
                    .foregroundStyle(kudoed ? .pink : .secondary)
                if count > 0 {
                    Text("\(count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy || !AuthService.shared.state.isSignedIn)
        .accessibilityLabel(kudoed ? "Remove kudos" : "Give kudos")
    }

    private func toggle() {
        guard !isBusy else { return }
        let previousKudoed = kudoed
        let previousCount = count

        // Optimistic update.
        kudoed.toggle()
        count = kudoed ? previousCount + 1 : max(0, previousCount - 1)
        UISelectionFeedbackGenerator().selectionChanged()

        isBusy = true
        Task {
            do {
                if previousKudoed {
                    try await SocialService.shared.unkudo(flightRowId: item.id)
                } else {
                    try await SocialService.shared.kudo(flightRowId: item.id)
                }
            } catch {
                // Revert on failure — the row keeps working.
                kudoed = previousKudoed
                count = previousCount
            }
            isBusy = false
        }
    }
}

// MARK: - Feed item card

/// One feed flight: pilot (tappable → profile), spot, relative date, duration,
/// flight-type badge and a kudos button. On a pilot's own profile the header
/// row is hidden (`showPilot: false`) since every row is the same pilot.
private struct FeedItemCard: View {
    let item: FeedItem
    var showPilot: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showPilot {
                HStack {
                    NavigationLink {
                        PilotProfileView(userId: item.userId)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "person.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.blue)
                            Text(item.pilotName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color.primary)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    if let type = item.flightType.flatMap(FlightType.init(rawValue:)) {
                        SocialFlightTypeBadge(type: type)
                    }
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "mappin.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                Text(item.spotName)
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer()
                if !showPilot, let type = item.flightType.flatMap(FlightType.init(rawValue:)) {
                    SocialFlightTypeBadge(type: type)
                }
            }

            HStack(spacing: 8) {
                Text(item.date, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("• \(socialDurationText(item.durationSeconds))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                KudosButton(item: item)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - CommunityFeedView

/// The feed of flights from pilots you follow. Pushed inside an existing
/// NavigationStack (Dashboard). Pull-to-refresh, empty / error / signed-out
/// states, and pilot names deep-link to their profile.
struct CommunityFeedView: View {
    private enum Phase {
        case loading
        case loaded([FeedItem])
        case failed
    }

    @State private var phase: Phase = .loading

    private var isSignedIn: Bool { AuthService.shared.state.isSignedIn }

    var body: some View {
        content
            .navigationTitle("Community Feed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink {
                        FindPilotsView()
                    } label: {
                        Label("Find pilots", systemImage: "person.badge.plus")
                    }
                }
            }
            .task { await load(force: false) }
    }

    @ViewBuilder
    private var content: some View {
        if !isSignedIn {
            ContentUnavailableView {
                Label("Sign in to see your feed", systemImage: "person.2")
            } description: {
                Text("Follow pilots and see their latest flights here. Sign in from Settings › Account to get started.")
            }
        } else {
            switch phase {
            case .loading:
                ProgressView("Loading feed…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed:
                ContentUnavailableView {
                    Label("Feed unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("Check your connection and try again.")
                } actions: {
                    Button("Retry") { Task { await load(force: true) } }
                        .buttonStyle(.borderedProminent)
                }
            case .loaded(let items):
                if items.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(items) { item in
                            FeedItemCard(item: item)
                        }
                    }
                    .listStyle(.plain)
                    .refreshable { await load(force: true) }
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No flights yet", systemImage: "person.2")
        } description: {
            Text("Follow pilots to see their flights here. Find them in Explore or on any spot's leaderboard.")
        } actions: {
            NavigationLink {
                ExploreView()
            } label: {
                Label("Explore spots", systemImage: "globe")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func load(force: Bool) async {
        if case .loaded = phase {} else if !force { phase = .loading }
        do {
            let items = try await SocialService.shared.feed(limit: 50)
            phase = .loaded(items)
        } catch {
            // Keep any stale list on a refresh failure; otherwise fail soft.
            if case .loaded = phase {} else { phase = .failed }
        }
    }
}

// MARK: - FindPilotsView

/// Search for pilots by name (prefix match on public profiles) and open
/// their profile to follow them. The invite ShareLink covers friends who
/// aren't on SoarX yet.
struct FindPilotsView: View {
    @State private var query = ""
    @State private var results: [PilotProfile] = []
    @State private var isSearching = false
    @State private var didSearch = false

    var body: some View {
        List {
            if results.isEmpty {
                Section {
                    if isSearching {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Searching…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if didSearch && !query.isEmpty {
                        Text("No pilot found with that name.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Type a pilot name to find them — then follow them from their profile.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Section {
                    ForEach(results) { pilot in
                        NavigationLink {
                            PilotProfileView(userId: pilot.userId)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "person.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(.blue)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(pilot.pilotName)
                                        .font(.subheadline.weight(.medium))
                                    if let home = pilot.homeSpotName, !home.isEmpty {
                                        Label(home, systemImage: "house")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }

            Section {
                ShareLink(item: "I log my flights with SoarX — paragliding & parakite logbook with Apple Watch tracking, 3D replay and live spot conditions from other pilots. Come fly with me!") {
                    Label("Invite a friend to SoarX", systemImage: "person.badge.plus")
                }
            } footer: {
                Text("Not on SoarX yet? Send them an invite by message, WhatsApp or anything else.")
            }
        }
        .navigationTitle("Find Pilots")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Pilot name")
        .task(id: query) {
            // Debounce: wait for a typing pause before hitting the backend.
            guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                results = []
                didSearch = false
                return
            }
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            isSearching = true
            defer { isSearching = false }
            results = (try? await SocialService.shared.searchPilots(matching: query)) ?? []
            didSearch = true
        }
    }
}

// MARK: - PilotProfileView

/// A pilot's profile. When `userId` is nil or matches the signed-in user the
/// view is the editable "my profile"; otherwise it's a read-only public
/// profile with a Follow button, follower/following counts and the pilot's
/// recent shared flights. Signed-out + own profile shows a friendly prompt.
struct PilotProfileView: View {
    let userId: String?

    private var isMine: Bool {
        guard let userId else { return true }
        return userId == currentUserId()
    }

    var body: some View {
        if isMine {
            MyProfileEditor()
        } else if let userId {
            PublicProfileView(userId: userId)
        }
    }
}

// MARK: My profile (editable)

private struct MyProfileEditor: View {
    @Query(sort: \Spot.name) private var spots: [Spot]

    @State private var pilotName = ""
    @State private var bio = ""
    @State private var homeSpotKey: String?
    @State private var homeSpotName = ""
    @State private var statsPublic = true

    @State private var isLoading = true
    @State private var isSaving = false
    @State private var didLoad = false
    @State private var statusMessage: String?
    @State private var saveFailed = false

    private var isSignedIn: Bool { AuthService.shared.state.isSignedIn }

    /// Local spots that can be mapped to a community key (have coordinates).
    private var locatedSpots: [(spot: Spot, key: String)] {
        spots.compactMap { spot in
            guard let key = keyFor(spot) else { return nil }
            return (spot, key)
        }
    }

    private var canSave: Bool {
        !pilotName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSaving
    }

    var body: some View {
        Group {
            if !isSignedIn {
                signedOutPrompt
            } else if isLoading {
                ProgressView("Loading profile…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                form
            }
        }
        .navigationTitle("My Pilot Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isSignedIn && !isLoading {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(!canSave)
                }
            }
        }
        .task { await load() }
    }

    private var signedOutPrompt: some View {
        ContentUnavailableView {
            Label("Sign in to set up your profile", systemImage: "person.crop.circle.badge.questionmark")
        } description: {
            Text("Your pilot profile is tied to your account. Sign in from Settings › Account to pick a name, bio and home spot.")
        }
    }

    private var form: some View {
        Form {
            Section {
                LabeledContent("Pilot name") {
                    TextField("A pilot", text: $pilotName)
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                }
            } header: {
                Text("Name")
            } footer: {
                Text("This is the public name other pilots see on your flights and reports.")
            }

            Section("Bio") {
                TextField("Add a short bio (optional)", text: $bio, axis: .vertical)
                    .lineLimit(1...4)
            }

            Section {
                Picker("Home spot", selection: $homeSpotKey) {
                    Text("None").tag(String?.none)
                    ForEach(locatedSpots, id: \.key) { entry in
                        Text(entry.spot.name).tag(Optional(entry.key))
                    }
                }
                .onChange(of: homeSpotKey) { _, newKey in
                    homeSpotName = locatedSpots.first { $0.key == newKey }?.spot.name ?? ""
                }
            } header: {
                Text("Home spot")
            } footer: {
                if locatedSpots.isEmpty {
                    Text("Add a spot with a location to pick a home spot.")
                }
            }

            Section {
                Toggle(isOn: $statsPublic) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Public stats")
                        Text("Let other pilots see your airtime on spot leaderboards.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let statusMessage {
                Section {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(saveFailed ? .red : .secondary)
                }
            }
        }
    }

    // MARK: Data

    private func keyFor(_ spot: Spot) -> String? {
        spot.communitySpotKey
            ?? CommunitySpotKey.make(name: spot.name, latitude: spot.latitude, longitude: spot.longitude)
    }

    private func load() async {
        guard !didLoad else { return }
        didLoad = true
        // Seed the public name from the existing Community setting so a
        // first-time profile isn't blank.
        pilotName = CommunityService.shared.pilotDisplayName
        guard isSignedIn else { isLoading = false; return }
        do {
            if let profile = try await SocialService.shared.myProfile() {
                pilotName = profile.pilotName
                bio = profile.bio ?? ""
                homeSpotKey = profile.homeSpotKey
                homeSpotName = profile.homeSpotName ?? ""
                statsPublic = profile.statsPublic
            }
        } catch {
            // Fail soft — the editor still works with the seeded name.
        }
        isLoading = false
    }

    private func save() async {
        let trimmedName = pilotName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        isSaving = true
        statusMessage = nil
        saveFailed = false
        do {
            try await SocialService.shared.upsertMyProfile(
                pilotName: trimmedName,
                bio: bio.isEmpty ? nil : bio,
                homeSpotKey: homeSpotKey,
                homeSpotName: homeSpotName.isEmpty ? nil : homeSpotName,
                statsPublic: statsPublic
            )
            // Keep the shared public name in sync with Settings › Community.
            CommunityService.shared.pilotDisplayName = trimmedName
            statusMessage = "Profile saved."
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            saveFailed = true
            statusMessage = (error as? LocalizedError)?.errorDescription ?? "Could not save your profile."
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
        isSaving = false
    }
}

// MARK: Public profile (read-only)

private struct PublicProfileView: View {
    let userId: String

    @State private var profile: PilotProfile?
    @State private var followerCount = 0
    @State private var followingCount = 0
    @State private var isFollowing = false
    @State private var recentFlights: [FeedItem] = []

    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var isTogglingFollow = false

    private var isSignedIn: Bool { AuthService.shared.state.isSignedIn }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading profile…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if loadFailed {
                ContentUnavailableView {
                    Label("Profile unavailable", systemImage: "person.crop.circle.badge.exclamationmark")
                } description: {
                    Text("Check your connection and try again.")
                } actions: {
                    Button("Retry") { Task { await load() } }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                profileList
            }
        }
        .navigationTitle(profile?.pilotName ?? "Pilot")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private var profileList: some View {
        List {
            Section {
                VStack(spacing: 10) {
                    Image(systemName: "person.circle.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.white, .blue)
                    Text(profile?.pilotName ?? "Pilot")
                        .font(.title3.weight(.semibold))
                    if let bio = profile?.bio, !bio.isEmpty {
                        Text(bio)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    if let home = profile?.homeSpotName, !home.isEmpty {
                        Label(home, systemImage: "house")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: 28) {
                        countBlock(recentFlights.count, "Flights")
                        countBlock(followerCount, "Followers")
                        countBlock(followingCount, "Following")
                    }
                    .padding(.top, 2)

                    if isSignedIn {
                        followButton
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                // Hero backdrop: same sky gradient family as onboarding/launch.
                .background(
                    LinearGradient(
                        colors: [Color.blue.opacity(0.30), Color.cyan.opacity(0.12), Color.clear],
                        startPoint: .top, endPoint: .bottom
                    ),
                    in: RoundedRectangle(cornerRadius: 16)
                )
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))

            // Records from the pilot's shared flights (best-effort — limited
            // to the recent-flights window the profile already loads).
            if let records = pilotRecords {
                Section {
                    HStack(spacing: 10) {
                        recordTile(records.longestText, "Longest flight", "clock.fill")
                        recordTile(records.hoursText, "Airtime", "sum")
                        recordTile("\(records.spotCount)", "Spots", "mappin.and.ellipse")
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
                } header: {
                    Text("Records")
                }
            }

            Section("Recent flights") {
                if recentFlights.isEmpty {
                    Text("No shared flights yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(recentFlights) { flight in
                        FeedItemCard(item: flight, showPilot: false)
                    }
                }
            }
        }
    }

    private func countBlock(_ value: Int, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(.headline.monospacedDigit())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Records

    private struct PilotRecords {
        let longestText: String
        let hoursText: String
        let spotCount: Int
    }

    /// Aggregates of the loaded shared flights; nil while there are none.
    private var pilotRecords: PilotRecords? {
        guard !recentFlights.isEmpty else { return nil }
        let longest = recentFlights.map(\.durationSeconds).max() ?? 0
        let total = recentFlights.reduce(0) { $0 + $1.durationSeconds }
        let hours = Double(total) / 3600
        return PilotRecords(
            longestText: socialDurationText(longest),
            hoursText: hours >= 10 ? "\(Int(hours.rounded())) h" : String(format: "%.1f h", hours),
            spotCount: Set(recentFlights.map(\.spotName)).count
        )
    }

    private func recordTile(_ value: String, _ label: String, _ symbol: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(.blue)
            Text(value)
                .font(.headline.weight(.bold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12))
    }

    private var followButton: some View {
        Button {
            Task { await toggleFollow() }
        } label: {
            Label(isFollowing ? "Following" : "Follow",
                  systemImage: isFollowing ? "checkmark" : "person.badge.plus")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(isFollowing ? .gray : .blue)
        .disabled(isTogglingFollow)
        .padding(.horizontal, 40)
    }

    // MARK: Data

    private func load() async {
        isLoading = true
        loadFailed = false
        do {
            let loaded = try await SocialService.shared.profile(userId: userId)
            profile = loaded
        } catch {
            loadFailed = profile == nil
            isLoading = false
            return
        }
        // Secondary details fail soft — a missing count never blocks the page.
        // (followerCount / followingCount / isFollowing are non-throwing.)
        async let followers = SocialService.shared.followerCount(of: userId)
        async let following = SocialService.shared.followingCount(of: userId)
        async let followed = isSignedIn ? SocialService.shared.isFollowing(userId) : false
        async let flights = (try? await SocialService.shared.recentFlights(of: userId, limit: 20)) ?? []
        followerCount = await followers
        followingCount = await following
        isFollowing = await followed
        recentFlights = await flights
        isLoading = false
    }

    private func toggleFollow() async {
        guard !isTogglingFollow else { return }
        isTogglingFollow = true
        let wasFollowing = isFollowing
        // Optimistic follow state + follower count.
        isFollowing.toggle()
        followerCount = max(0, followerCount + (isFollowing ? 1 : -1))
        UISelectionFeedbackGenerator().selectionChanged()
        do {
            if wasFollowing {
                try await SocialService.shared.unfollow(userId)
            } else {
                try await SocialService.shared.follow(userId, pilotName: profile?.pilotName ?? "")
            }
        } catch {
            // Revert on failure.
            isFollowing = wasFollowing
            followerCount = max(0, followerCount + (wasFollowing ? 1 : -1))
        }
        isTogglingFollow = false
    }
}

// MARK: - SpotLeaderboardSection

/// A List Section ranking pilots at one spot over today / this week /
/// all-time. Compact rows (rank, pilot, airtime, flight count); the current
/// user's row is highlighted. Hides itself entirely when the backend isn't
/// configured (or the leaderboard can't load at all).
struct SpotLeaderboardSection: View {
    let spotKey: String
    let spotName: String

    private enum Phase {
        case loading
        case loaded([LeaderboardEntry])
        /// Backend not configured / unavailable: render nothing.
        case hidden
    }

    @State private var period: LeaderboardPeriod = .week
    @State private var phase: Phase = .loading

    /// The signed-in pilot's public name, to highlight their own row (the
    /// entries carry no userId, so name is the fallback signal).
    private var myName: String {
        CommunityService.shared.pilotDisplayName
    }

    var body: some View {
        switch phase {
        case .hidden:
            EmptyView()
        default:
            section
        }
    }

    private var section: some View {
        Section {
            Picker("Period", selection: $period) {
                Text("Today").tag(LeaderboardPeriod.today)
                Text("Week").tag(LeaderboardPeriod.week)
                Text("All-time").tag(LeaderboardPeriod.allTime)
            }
            .pickerStyle(.segmented)

            switch phase {
            case .loading:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading leaderboard…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .loaded(let entries):
                if entries.isEmpty {
                    Text("No ranked flights for this period yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        LeaderboardRow(rank: index + 1, entry: entry, highlighted: isMe(entry))
                    }
                }
            case .hidden:
                EmptyView()
            }
        } header: {
            Text("Leaderboard")
                // Attached to the header (a plain view), not the Section.
                .task(id: period) { await load() }
        } footer: {
            if case .loaded(let entries) = phase, !entries.isEmpty {
                Text("Airtime from pilots who share their flights here.")
            }
        }
    }

    private func isMe(_ entry: LeaderboardEntry) -> Bool {
        if let me = currentUserId(), entry.id == me { return true }
        let trimmed = myName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && entry.pilotName == trimmed
    }

    private func load() async {
        if case .loaded = phase {} else { phase = .loading }
        do {
            let entries = try await SocialService.shared.leaderboard(spotKey: spotKey, period: period)
            phase = .loaded(entries)
        } catch {
            // Fail soft: hide the section rather than showing an error.
            if case .loaded = phase {} else { phase = .hidden }
        }
    }
}

/// One leaderboard row: rank, pilot (tappable → profile), airtime, flights.
private struct LeaderboardRow: View {
    let rank: Int
    let entry: LeaderboardEntry
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 10) {
            Text("\(rank)")
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(rankColor)
                .frame(width: 22, alignment: .trailing)

            NavigationLink {
                // The entry id doubles as the pilot's userId; a wrong id just
                // fails soft in the profile loader.
                PilotProfileView(userId: entry.id)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.pilotName)
                        .font(.subheadline.weight(highlighted ? .bold : .medium))
                        .lineLimit(1)
                    Text("^[\(entry.flightCount) flight](inflect: true)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            Text(socialDurationText(entry.totalSeconds))
                .font(.subheadline.weight(.medium).monospacedDigit())
        }
        .padding(.vertical, 2)
        .listRowBackground(highlighted ? Color.blue.opacity(0.10) : nil)
    }

    /// Gold / silver / bronze for the podium, secondary below.
    private var rankColor: Color {
        switch rank {
        case 1: return .yellow
        case 2: return .gray
        case 3: return .orange
        default: return .secondary
        }
    }
}
