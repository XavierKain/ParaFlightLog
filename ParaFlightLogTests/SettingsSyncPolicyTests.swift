//
//  SettingsSyncPolicyTests.swift
//  ParaFlightLogTests
//
//  Merge rule for the Watch-synced settings: the most recent edit wins,
//  whichever device made it.
//
//  Before this policy existed neither side had any notion of ordering, so the
//  iPhone re-published its settings on every session activation and silently
//  reverted a setting the pilot had just changed on the Watch. These cases pin
//  the rule down; the same function runs on both devices.
//

import Foundation
import Testing
@testable import ParaFlightLog

@Suite("Watch settings merge policy")
struct SettingsSyncPolicyTests {

    /// The regression: the iPhone re-publishing its (older) state on launch
    /// must not overwrite a change the pilot just made on the Watch.
    @Test func staleRepublishDoesNotOverwriteANewerLocalEdit() {
        let watchEditedAt = 1_000.0
        let phoneRepublishesItsOlderState = 900.0
        #expect(
            SettingsSyncPolicy.shouldApply(
                incomingStamp: phoneRepublishesItsOlderState,
                localStamp: watchEditedAt
            ) == false
        )
    }

    @Test func newerRemoteEditWins() {
        #expect(SettingsSyncPolicy.shouldApply(incomingStamp: 1_001, localStamp: 1_000))
    }

    /// Equal stamps mean both sides already agree. Applying would be a no-op at
    /// best, and re-emitting it is how two devices start bouncing a payload
    /// back and forth, so the local value stands.
    @Test func equalStampsKeepTheLocalValue() {
        #expect(SettingsSyncPolicy.shouldApply(incomingStamp: 1_000, localStamp: 1_000) == false)
    }

    /// A payload from a build that predates stamping carries no version. It is
    /// accepted so a mixed-version pair keeps syncing as it always did.
    @Test func unstampedLegacyPayloadIsAccepted() {
        #expect(SettingsSyncPolicy.shouldApply(incomingStamp: nil, localStamp: 1_000))
    }

    /// A device that has never had a local edit holds stamp 0, so the very
    /// first payload from the other side must land.
    @Test func firstPayloadLandsOnADeviceThatNeverEditedAnything() {
        #expect(SettingsSyncPolicy.shouldApply(incomingStamp: 1.0, localStamp: 0))
    }

    /// Full round trip: Watch edits, iPhone adopts, then the iPhone's own
    /// activation re-publish (same stamp) is correctly ignored by the Watch.
    @Test func watchEditPropagatesOnceAndTheEchoIsDropped() {
        let watchStamp = 2_000.0
        var phoneStamp = 1_500.0

        #expect(SettingsSyncPolicy.shouldApply(incomingStamp: watchStamp, localStamp: phoneStamp))
        phoneStamp = watchStamp   // the iPhone adopts the Watch's stamp

        // The iPhone now re-publishes on its next activation, carrying that same
        // stamp back to the Watch, which must not reapply it.
        #expect(
            SettingsSyncPolicy.shouldApply(incomingStamp: phoneStamp, localStamp: watchStamp) == false
        )
    }
}
