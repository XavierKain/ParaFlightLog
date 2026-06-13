//
//  SoarXLiveActivityBundle.swift
//  SoarXLiveActivity
//
//  Point d'entrée de l'extension Live Activity iOS.
//

import WidgetKit
import SwiftUI

@main
struct SoarXLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        FlightLiveActivity()
    }
}
