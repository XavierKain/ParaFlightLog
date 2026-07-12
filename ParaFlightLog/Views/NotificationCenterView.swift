//
//  NotificationCenterView.swift
//  ParaFlightLog
//
//  The in-app notification center (bell): unread notifications first, then
//  earlier ones. Tapping a row marks it read and — when its spotKey resolves
//  to a local spot — opens that spot's page. Swipe to delete, "Mark all read"
//  in the toolbar, and an empty state.
//
//  Fed by NotificationInboxService (live pushes + recovered missed reports).
//  Target: iOS only
//

import SwiftUI

struct NotificationCenterView: View {
    @Environment(DataController.self) private var dataController: DataController?
    @Environment(\.dismiss) private var dismiss

    /// Observed singleton — the list and unread state update live.
    private var inbox: NotificationInboxService { NotificationInboxService.shared }

    /// Local spot to push when a notification is tapped (nil = nothing open).
    @State private var openedSpot: Spot?

    private var unread: [InboxItem] { inbox.items.filter { !$0.isRead } }
    private var earlier: [InboxItem] { inbox.items.filter { $0.isRead } }

    var body: some View {
        NavigationStack {
            Group {
                if inbox.items.isEmpty {
                    ContentUnavailableView(
                        "No notifications",
                        systemImage: "bell.slash",
                        description: Text("Reports from spots you follow and other alerts will show up here.")
                    )
                } else {
                    List {
                        if !unread.isEmpty {
                            Section("Unread") {
                                ForEach(unread) { item in
                                    row(item)
                                }
                                .onDelete { offsets in delete(offsets, from: unread) }
                            }
                        }
                        if !earlier.isEmpty {
                            Section("Earlier") {
                                ForEach(earlier) { item in
                                    row(item)
                                }
                                .onDelete { offsets in delete(offsets, from: earlier) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Mark all read") { inbox.markAllRead() }
                        .disabled(unread.isEmpty)
                }
            }
            .navigationDestination(item: $openedSpot) { spot in
                SpotDetailView(spot: spot)
            }
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func row(_ item: InboxItem) -> some View {
        Button {
            open(item)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                // Unread marker keeps its column so read/unread rows align.
                Circle()
                    .fill(item.isRead ? Color.clear : Color.blue)
                    .frame(width: 8, height: 8)
                    .padding(.top, 6)

                Image(systemName: item.kind.symbol)
                    .font(.system(size: 18))
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.subheadline.weight(item.isRead ? .regular : .semibold))
                        .foregroundStyle(Color.primary)
                    if !item.body.isEmpty {
                        Text(item.body)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    Text(item.date, format: .relative(presentation: .named))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer(minLength: 0)

                if item.spotKey != nil {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    /// Marks the item read and, when its spotKey resolves to a local spot,
    /// navigates to that spot. A non-resolving key just marks it read.
    private func open(_ item: InboxItem) {
        inbox.markRead(item.id)
        guard let spotKey = item.spotKey,
              let spot = resolveSpot(forKey: spotKey) else { return }
        openedSpot = spot
    }

    private func resolveSpot(forKey spotKey: String) -> Spot? {
        dataController?.fetchSpots().first { spot in
            spot.communitySpotKey == spotKey
                || CommunitySpotKey.make(
                    name: spot.name,
                    latitude: spot.latitude,
                    longitude: spot.longitude
                ) == spotKey
        }
    }

    private func delete(_ offsets: IndexSet, from source: [InboxItem]) {
        for index in offsets {
            inbox.delete(source[index].id)
        }
    }
}
