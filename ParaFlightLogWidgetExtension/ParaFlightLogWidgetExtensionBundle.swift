//
//  ParaFlightLogWidgetExtensionBundle.swift
//  ParaFlightLogWidgetExtension
//
//  Created by Xavier Kain on 01/12/2025.
//

import WidgetKit
import SwiftUI

@main
struct ParaFlightLogWidgetExtensionBundle: WidgetBundle {
    var body: some Widget {
        ParaFlightLogWidget()
        // Live Activity for phone-tracked flights. Guarded: this target
        // currently builds for watchOS where ActivityKit doesn't exist;
        // the activity registers itself on iOS widget-extension builds.
        #if os(iOS) && canImport(ActivityKit)
        FlightLiveActivity()
        #endif
    }
}
