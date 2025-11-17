//
//  Item.swift
//  ParaFlightLog
//
//  Created by Xavier Kain on 17/11/2025.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
