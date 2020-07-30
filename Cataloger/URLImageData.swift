//
//  URLImageData.swift
//  Cataloger
//
//  Created by Maxim Lu on 7/27/20.
//  Copyright © 2020 Maxim Lu. All rights reserved.
//

import Foundation
import SwiftUI

class URLImageData : ObservableObject{
    @Published var data : Data = Data()
    
    init(imageUrlString:String){
        guard let url = URL(string: imageUrlString) else {return}
        
        URLSession.shared.dataTask(with: url) {
            (data,response,error) in
            guard let data = data else {return}
            DispatchQueue.main.async {
                self.data = data
            }
        }.resume()
    }
}
