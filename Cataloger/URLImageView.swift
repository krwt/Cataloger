//
//  URLImageView.swift
//  Cataloger
//
//  Created by Maxim Lu on 7/27/20.
//  Copyright © 2020 Maxim Lu. All rights reserved.
//

import SwiftUI

struct URLImageView: View {
    @ObservedObject var urlImageData : URLImageData
    
    init(imageUrlString:String){
        urlImageData = URLImageData(imageUrlString:imageUrlString)
    }
    
    var body: some View {
        Image(uiImage: (urlImageData.data.isEmpty) ? UIImage(systemName:"square.and.arrow.down")! : ( UIImage(data:urlImageData.data) ?? UIImage(systemName: "rectangle.slash")!)).resizable().scaledToFit()
    }
}

struct URLImageView_Previews: PreviewProvider {
    static var previews: some View {
        URLImageView(imageUrlString:"https://i.imgur.com/0tp5gZD.jpg")
    }
}
