//
//  ScreenshotTests.swift
//  ParaFlightLogUITests
//
//  UI Tests for App Store screenshots
//

import XCTest

final class ScreenshotTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testScreenshots() throws {
        let app = XCUIApplication()
        setupSnapshot(app)
        app.launch()

        // Wait for app to load
        sleep(2)

        // 1. Home screen - Flight list
        snapshot("01_Flights")

        // 2. Navigate to Statistics tab
        let statsTab = app.tabBars.buttons.element(boundBy: 1)
        if statsTab.exists {
            statsTab.tap()
            sleep(1)
            snapshot("02_Statistics")
        }

        // 3. Navigate to Wings tab
        let wingsTab = app.tabBars.buttons.element(boundBy: 2)
        if wingsTab.exists {
            wingsTab.tap()
            sleep(1)
            snapshot("03_Wings")
        }

        // 4. Navigate to Settings tab
        let settingsTab = app.tabBars.buttons.element(boundBy: 3)
        if settingsTab.exists {
            settingsTab.tap()
            sleep(1)
            snapshot("04_Settings")
        }

        // 5. Go back to Flights and try to open a flight detail if available
        let flightsTab = app.tabBars.buttons.element(boundBy: 0)
        if flightsTab.exists {
            flightsTab.tap()
            sleep(1)

            // Try to tap on first flight cell if exists
            let firstCell = app.cells.element(boundBy: 0)
            if firstCell.exists {
                firstCell.tap()
                sleep(1)
                snapshot("05_FlightDetail")
            }
        }
    }
}
