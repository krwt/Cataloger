//
//  Item.swift
//  Cataloger
//
//  Created by Maxim Lu on 7/20/20.
//  Copyright © 2020 Maxim Lu. All rights reserved.
//

import Foundation
import SwiftUI
struct Item: Hashable,Codable,Identifiable{
    var id: Int = -1
    var name : String = ""
    var description: String = ""
    //var location: String = ""
    var fullLocation: String = "TBD"
    var imgUrl : URL?
    var uuid : String = "" //this is for saved image
    var uuidForLabel : String = "" // this is for qr label
}

class Items:NSObject,ObservableObject{
    @Published var fullList: [Item] = []
    @Published var id = 0 //i guess this is meant to be count?
    @Published var dataLoaded : Bool = false
    @Published var pendingUploads: [Item] = []
    @Published var errorMessage : String = ""
    func save(){
        guard let  rootDir = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {return}
        let documentsDir = rootDir.appendingPathComponent("Documents")
        let dataDir = documentsDir.appendingPathComponent("data.mcs")
        var rewrite = ""
        for each in self.fullList{
            let url = each.imgUrl?.absoluteString ?? ""
            let line = each.name+","+each.description+","+each.fullLocation+","+url+","+each.uuid+","+each.uuidForLabel+"\n"
            rewrite.append(line)
        }
        do {
            try rewrite.write(to: dataDir, atomically: true, encoding: .utf8)
        } catch {
            print("error writing to file : \(error)")
            self.errorMessage = "**error writing saved to file**"
        }
    }
    
    func update(){
        guard let  rootDir = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {return}
        let documentsDir = rootDir.appendingPathComponent("Documents")
        let dataDir = documentsDir.appendingPathComponent("data.mcs")
        let each = self.fullList[self.id-1]
        let url = each.imgUrl?.absoluteString ?? ""
        let uuid = each.uuid
        let line = each.name+","+each.description+","+each.fullLocation+","+url+","+uuid+","+each.uuidForLabel
        
        do {
            try line.appendLineToURL(fileURL: dataDir)
        } catch {
            print("error appending to file \(error)")
            self.errorMessage = "**error updating new entry to file**"
        }
    }
    
    func reloadData(){
        self.fullList = []
        self.id = 0
        self.dataLoaded = false
        self.getData {
            self.dataLoaded = true
        }
    }
    
    func removeHEICFromiCloud(fileName:String){
        guard let  rootDir = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {return}
        let documentsDir = rootDir.appendingPathComponent("Documents")
        let imgDir = documentsDir.appendingPathComponent("img")
        let filename = imgDir.appendingPathComponent(fileName)
        do {
            try FileManager.default.removeItem(at: filename)
        }catch
        {
            return
        }
    }
    
    func saveHEICtoiCloud(image: UIImage?,uuid:String){
        guard let  rootDir = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {return}
        guard let image = image else {
            return
        }
        let documentsDir = rootDir.appendingPathComponent("Documents")
        let imgDir = documentsDir.appendingPathComponent("img")
        let fileUrl = imgDir.appendingPathComponent("\(uuid).heic")
        let heicData = image.heic(compressionQuality: 0.15)
        FileManager.default.createFile(atPath: fileUrl.path, contents: heicData, attributes: nil)
    }
    
    func getData(completion: @escaping ()-> Void){
        guard let  rootDir = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {return}
        let documentsDir = rootDir.appendingPathComponent("Documents")
        let dataDir = documentsDir.appendingPathComponent("data.mcs")
        if FileManager.default.fileExists(atPath: dataDir.path){
            print("data file found on cloud, reading")
            do {
                //let data = try Data(contentsOf: dataDir)
                //let splitData = data.withUnsafeBytes { $0.split(separator: UInt8(ascii: "\n"))}
                let str = try String(contentsOf: dataDir)
                let splitData = str.components(separatedBy: "\n")
                for each in splitData{
//                    if splitData.firstIndex(of: each) == 0{
//                        continue
//                    }
                    print("splitdata(line): \(each)")
                    let components = each.components(separatedBy: ",")
                    if components.count < 5 {
                        continue
                    }
                    print("components: \(components)")
                    let currentId = self.id
                    let name = components[0]
                    let description = components[1]
                    let fullLocation = components[2]
                    //var location = fullLocation[fullLocation.lastIndex(of: "/")!...]
                    //location.removeFirst()
                    let imgurUrl = components[3].replacingOccurrences(of: " ", with: "")
                    let uuid = components[4]
                    var newRow = Item(id: currentId, name: name, description: description, fullLocation: fullLocation, imgUrl: URL(string: imgurUrl),uuid:uuid)
                    if components.count == 6{
                        let uuidForLabel = components[5]
                        newRow.uuidForLabel = uuidForLabel
                    }
                    self.fullList.append(newRow)
                    self.id += 1
                }
            } catch {
                print("error reading data from file : \(error)")
            }
        } else {
            print("no data file found on cloud")
            //start download file to icloud
            let ghosturl = documentsDir.appendingPathComponent(".data.mcs.icloud")
            
            
            if FileManager.default.fileExists(atPath: ghosturl.path){
                print("file ghost exist")
                do {
                  try FileManager.default.startDownloadingUbiquitousItem(at: ghosturl )
                } catch {
                  print("Unexpected error: \(error).")
                }
            }
            else {
                print("file ghost does not exist")
            }
            /*
            let fileManager = FileManager.default
            if let urls = try? fileManager.contentsOfDirectory(at: documentsDir, includingPropertiesForKeys: nil, options: [])
            {  // Here select the file url you are interested in
                    if let myURL = urls.first {
                // We have the url we want to download into myURL variable
                    }
                for each in urls {
                    print(each)
                }
            }
            */
            return
        }
        for each in fullList {
            print(each)
        }
        completion()
    }
    
}
