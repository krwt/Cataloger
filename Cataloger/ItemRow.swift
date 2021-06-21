//
//  ItemRow.swift
//  Cataloger
//
//  Created by Maxim Lu on 7/20/20.
//  Copyright © 2020 Maxim Lu. All rights reserved.
//

import SwiftUI

struct ItemRow: View {
    var item: Item
    var body: some View {
        HStack{
            if #available(macCatalyst 14.0, *) {
                Text(item.name).frame(alignment: .leading).font(.title2)
            } else {
                Text(item.name).frame(alignment: .leading)
                // Fallback on earlier versions
            }
            Divider()
            Text(item.description)
            Divider()
            Text(item.fullLocation)
            Spacer()
            //Image(systemName: "photo").scaledToFill().frame(width: 50, height: 50, alignment: /*@START_MENU_TOKEN@*/.center/*@END_MENU_TOKEN@*/).imageScale(.large)
        }.frame(height:70)//.border(Color.green,width:1)
    }
}

struct ItemRow_Previews: PreviewProvider {
    static var previews: some View {
        Group{
            ItemRow(item: itemSample0)
            ItemRow(item: itemSample1)
            ItemRow(item: itemSample2)
        }.previewLayout(.fixed(width: 300, height: 70))
    }
}
