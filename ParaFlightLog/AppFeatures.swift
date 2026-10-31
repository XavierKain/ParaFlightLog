//
//  AppFeatures.swift
//  ParaFlightLog
//
//  Feature switches that decide which halves of the app exist.
//  Target: iOS only
//

import Foundation
import SwiftUI

/// Which parts of SoarX are visible.
///
/// There is deliberately no second build or second target here: the community
/// half is hidden, not removed, so the same binary serves a pilot who only
/// logs flights and one who uses the feed — and switching between the two
/// never touches the database.
///
/// Why off by default: the community surfaces show other pilots' content, and
/// App Review's user-generated-content rules expect reporting, blocking and an
/// EULA before that can ship to testers. Until those exist, a build going out
/// to other people is a logbook.
nonisolated enum AppFeatures {

    /// Explore, community feed, pilot profiles, spot condition reports, the
    /// shared wing library and flight sharing.
    ///
    /// Non-View code (services, the share path) reads this directly; views go
    /// through `.communityOnly()` or their own `@AppStorage` so flipping the
    /// switch takes effect without relaunching.
    static var communityEnabled: Bool {
        UserDefaults.standard.object(forKey: UserDefaultsKeys.communityEnabled) as? Bool ?? false
    }
}

/// Drops the content unless the community half is on. A `ViewModifier` rather
/// than a plain `if`, so the gate reads the default through `@AppStorage` and
/// the UI follows the switch live.
private struct CommunityGate: ViewModifier {
    @AppStorage(UserDefaultsKeys.communityEnabled) private var enabled = false

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content
        }
    }
}

extension View {
    /// Hides this entry point when the community half is off.
    /// Not usable on `ToolbarContent` (a toolbar item is not a `View`) — gate
    /// those with an `@AppStorage` flag in the enclosing view instead.
    func communityOnly() -> some View {
        modifier(CommunityGate())
    }
}
