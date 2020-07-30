//
//  SwiftUIView.swift
//  Cataloger
//
//  Created by Maxim Lu on 7/23/20.
//  Copyright © 2020 Maxim Lu. All rights reserved.
//

import SwiftUI


struct iCloudAlert: View {
    @Binding var showAlert : Bool
    @Binding var sheetToShow : Bool
    var body: some View {
        VStack{
            Text("IMPORTANT!!!!!").font(.largeTitle).foregroundColor(.red)
            Text("Download and open data.mcs to ensure file in local on device and up to date").padding(.all   , 20).foregroundColor(.red)
            Button(action: {openFilesApp()}, label: {
                Text("Go To Files App").font(.largeTitle)
            })
        Spacer()
        Button("Dismiss") {
            showAlert = false
            sheetToShow = false
        }.padding(/*@START_MENU_TOKEN@*/.all/*@END_MENU_TOKEN@*/, 20)
        }
    }
    
    func openFilesApp(){
        guard let rootDir = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {return}
        let documentsUrl = rootDir.appendingPathComponent("Documents",isDirectory: true)
        let sharedurl = documentsUrl.absoluteString.replacingOccurrences(of: "file://", with: "shareddocuments://")
        
        //let openUrl = URL(string: sharedurl)!
        #if targetEnvironment(macCatalyst)
        let openUrl = documentsUrl
        #else
        let openUrl = URL(string: sharedurl)!
        #endif
        UIApplication.shared.open(openUrl, options: [:]) { (succeed) in
            if succeed {
                self.showAlert = false
                self.sheetToShow = false
            } else {
                print("openfiles failed")
            }
        }
        //#endif
        
    }
}

struct iCloudAlert_Previews: PreviewProvider {
    static var previews: some View {
        iCloudAlert(showAlert: .constant(true),sheetToShow: .constant(false))
    }
}
