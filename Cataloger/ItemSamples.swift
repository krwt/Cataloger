//
//  ItemSamples.swift
//  Cataloger
//
//  Created by Maxim Lu on 7/21/20.
//  Copyright © 2020 Maxim Lu. All rights reserved.
//

import Foundation

let sampleImgurUrl = URL(string: "https://i.imgur.com/Yt08PS6.png")!

let itemSample0 = Item(id: 0, name: "pogo pins", description: "some pogo pins. length varies from 3mm to 20m. diameter unknown. similar to safty pin diameter", fullLocation: "A1/S2", imgUrl: sampleImgurUrl)

let itemSample1 = Item(id: 1, name: "wireless charger coil", description: "wireless charger coil, support 5w max, use microusb as input", fullLocation: "A2", imgUrl: sampleImgurUrl)

let itemSample2 = Item(id: 2, name: "mini brush", description: "small brush",  fullLocation: "A5", imgUrl: sampleImgurUrl)

let itemSampleList = [itemSample0,itemSample1,itemSample2]

let itemSamples: Items = Items()




