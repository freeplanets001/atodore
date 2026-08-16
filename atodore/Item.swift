//
//  Item.swift
//  atodore
//
//  Created by Tomonori_Ueda on 2026/08/16.
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
