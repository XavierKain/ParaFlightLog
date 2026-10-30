//
//  ModelRegistrationTests.swift
//  ParaFlightLogTests
//
//  Guards the one mistake that compiles, passes every other test, and still
//  loses the user's data: a @Model missing from the container's schema.
//
//  It happened with Reserve. Tests built their own container listing the model
//  explicitly, so they all passed, while the app's own container did not know
//  the entity — inserts went nowhere and "Save" silently did nothing.
//

import Foundation
import SwiftData
import Testing
@testable import ParaFlightLog

@Suite("Persisted models are registered")
struct ModelRegistrationTests {

    private var registeredNames: Set<String> {
        Set(DataController.registeredModels.map { String(describing: $0) })
    }

    /// Every model the app persists must be in the list the container is
    /// built from. Add a @Model, add it here.
    @Test func everyPersistedModelIsRegistered() {
        let expected: Set<String> = [
            "Wing", "Flight", "Spot", "TrashedFlight", "ArchivedSpotReport", "Reserve"
        ]
        #expect(registeredNames == expected)
    }

    /// The list must actually produce a usable container — a name in an array
    /// proves nothing on its own.
    @Test func theRegisteredListBuildsAWorkingContainer() throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(
            for: Schema(DataController.registeredModels),
            configurations: configuration
        )
        let context = ModelContext(container)

        // Round-trip the model that was missing, through the real schema.
        context.insert(Reserve(name: "Round trip", repackLog: [RepackEvent(date: Date())]))
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Reserve>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.name == "Round trip")
        #expect(fetched.first?.lastRepackDate != nil)
    }
}
