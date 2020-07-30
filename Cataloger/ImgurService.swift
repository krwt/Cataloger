//
//  File.swift
//  Cataloger
//
//  Created by Maxim Lu on 7/19/20.
//  Copyright © 2020 Maxim Lu. All rights reserved.
//

import Foundation
import SwiftUI
import Combine

extension String {
    subscript(_ range: CountableRange<Int>) -> String {
        let start = index(startIndex, offsetBy: max(0, range.lowerBound))
        let end = index(start, offsetBy: min(self.count - range.lowerBound,
                                             range.upperBound - range.lowerBound))
        return String(self[start..<end])
    }

    subscript(_ range: CountablePartialRangeFrom<Int>) -> String {
        let start = index(startIndex, offsetBy: max(0, range.lowerBound))
         return String(self[start...])
    }
}
extension Notification.Name{
    static let imgurCallBack = Notification.Name(rawValue: "imgurCallBack")
}

extension String {
  var urlQueryStringParameters: Dictionary<String, String> {
    // breaks apart query string into a dictionary of values
    var params = [String: String]()
    let items = self.split(separator: "&")
    for item in items {
      let combo = item.split(separator: "=")
      if combo.count == 2 {
        let key = "\(combo[0])"
        let val = "\(combo[1])"
        params[key] = val
      }
    }
    return params
  }
}
//
//cataloger://?state=login#access_token=0f38ebbb0a138ca0faf8e5ded8b82f6693ea1ac2&expires_in=315360000&token_type=bearer&refresh_token=2a945f04b1ba3b28876485542b871f8f60ecfc98&account_username=maximlv&account_id=30855933
//
class ImgurService: NSObject, ObservableObject {
    
    struct newAlbumResponseData : Decodable,Hashable{
        let id : String?
        let deletehash: String?
    }
    
    struct newAlbumResponse : Decodable,Hashable {
        let data : newAlbumResponseData?
        let success : Bool?
        let status: Int?
    }
    struct uploadResponseData : Decodable,Hashable {
        let link : String?
        let in_gallery: Bool?
    }
    
    struct uploadResponse : Decodable,Hashable {
        let data : uploadResponseData?
        let success : Bool?
        let status: Int?
    }
    
    let clientId = "2691de281566831"
    let clientSecret = "e1d9287a72373e861a1d284bec883360eae8257b"
    let callBackUrl = "cataloger"
    @Published var showSheet: Bool = false
    @Published var accessToken: String?
        = UserDefaults.standard.string(forKey: "accessToken")
    @Published var refreshToken: String?
        = UserDefaults.standard.string(forKey: "refreshToken")
    @Published var requestUrl : URL?
    @Published var loggedIn : Bool = false
    @Published var userName : String?  = UserDefaults.standard.string(forKey: "userName")
    @Published var buttonEnabled : Bool = false
    @Published var lastLogIn : Double?
        = UserDefaults.standard.double(forKey: "lastLogIn")
    @Published var errorMessage : String = ""
    @Published var albumId : String? = UserDefaults.standard.string(forKey: "albumId")
    @Published var uploadedImageUrlString = ""
    @Published var imageUploaded = false
    @Published var uploading = false
    //@Published var pub : AnyPublisher<newAlbumResponse, Error>?
    
    @Published var sub : Cancellable?
    var callBackNotificationObserver : Any?
    
    func CheckLogInStatus(){
        guard let ll = lastLogIn else {self.buttonEnabled = true;self.loggedIn = false;return}
        if Date().timeIntervalSince1970 - ll >= 2592000{
            self.buttonEnabled = true
            self.loggedIn = false
        } else {
            self.loggedIn = true
            self.buttonEnabled = false
        }
    }
    
    func logIn(){
        self.showSheet = true
        let requestUrlString = "https://api.imgur.com/oauth2/authorize?client_id="+clientId+"&response_type=token&state=login"
        requestUrl = URL(string: requestUrlString)
        callBackNotificationObserver = NotificationCenter.default.addObserver(forName: .imgurCallBack, object: nil, queue: .main, using: { (notification) in
            
            guard let url = notification.object as? URL else {return}
            print("imgur callbackUrl is \(url.absoluteString)")
            let urlString = url.absoluteString
            let sanitizedUrl = String(urlString[urlString.firstIndex(of: "#")!...].dropFirst())
            
            print("sanitized return url string \(sanitizedUrl)")
            let urlParams = sanitizedUrl.urlQueryStringParameters
            print("parsed return url string: \(urlParams)")
            if let at = urlParams["access_token"], let rt = urlParams["refresh_token"], let un = urlParams["account_username"] {
                self.accessToken = at
                self.refreshToken = rt
                self.userName = un
                UserDefaults.standard.setValue(self.accessToken, forKey: "accessToken")
                UserDefaults.standard.setValue(self.refreshToken, forKey: "refreshToken")
                UserDefaults.standard.setValue(self.userName, forKey: "userName")
                UserDefaults.standard.setValue(Date().timeIntervalSince1970, forKey: "lastLogIn")
                self.callBackNotificationObserver = nil
                self.showSheet = false
                self.loggedIn = true
                //self.requestUrl = nil
                
            } else {
                print("something wrong parsing callback url to get tokens and info")
            }
        })
    }
    
    func uploadImage(image:UIImage,name:String,description:String){
        //name. title description album
        //request.addValue("Bearer \(self.accessToken)", forHTTPHeaderField: "Authorization")
        print(self.accessToken)
        print(self.albumId)
        guard let accessToken = self.accessToken, let albumId = self.albumId else {
            self.uploading = false
            self.errorMessage = "missing imgur accessToken or Album Id"
            return
        }
        var parameters = [
          [
            "key": "image",
            "value": image.jpegData(compressionQuality: 0.01)?.base64EncodedString(options: .lineLength64Characters) ?? "",
            "type": "text"
          ],
          [
            "key": "album",
            "value": albumId,
            "type": "text"
          ],
          [
            "key": "title",
            "value": "name",
            "type": "text"
          ],
          [
            "key": "description",
            "value": "description",
            "type": "text"
          ],
          [
            "key": "type",
            "value": "base64",
            "type": "text"
        ]] as [[String:Any]]
    
        let boundary = "Boundary-\(UUID().uuidString)"
        var body = ""
        var error: Error? = nil
        for param in parameters {
          if param["disabled"] == nil {
            let paramName = param["key"]!
            body += "--\(boundary)\r\n"
            body += "Content-Disposition:form-data; name=\"\(paramName)\""
            let paramType = param["type"] as! String
            if paramType == "text" {
              let paramValue = param["value"] as! String
              body += "\r\n\r\n\(paramValue)\r\n"
            } else {
              return
            }
          }
        }
        body += "--\(boundary)--\r\n";
        let postData = body.data(using: .utf8)

        var request = URLRequest(url: URL(string: "https://api.imgur.com/3/upload")!,timeoutInterval: 10)
        request.addValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpMethod = "POST"
        request.httpBody = postData
//        URLSession.shared.dataTask(with: request) {
//            data, response,error in
//            self.uploading = false
//            if let data = data, let dataString = String(data: data, encoding: .utf8) {
//                print("data is \(dataString)")
//            }
//            print(response)
//            print(error)
//        }//.resume()

            let pub = URLSession.shared.dataTaskPublisher(for: request).print("uploadTest").tryMap { data,response -> Data in
                guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
                    print("upload response is not 200")
                    self.errorMessage = "upload response is not 200)"
                    return data
                }
                return data
            }.decode(type: uploadResponse.self, decoder: JSONDecoder()).receive(on: RunLoop.main).eraseToAnyPublisher()
        
        
            self.sub = pub.sink(receiveCompletion: {completion in
                switch completion {
                case .finished:
                    //do something
                    print("upload finished")
                    self.uploading = false
                    break
                case .failure(let anError):
                    self.uploading = false
                    print("upload received error \(anError)")
                    self.errorMessage = "upload completed with failure"
                }
            }, receiveValue: { receivedValue in
                print("upload receveid" )
                print("\(receivedValue)")
                guard let uploadResult : uploadResponse = receivedValue,
                      let success = uploadResult.success,
                      let data = uploadResult.data,
                      let urlString = data.link,
                      let inGallery = data.in_gallery else {
                    self.errorMessage = "error parsing upload received data "
                    return
                }

                guard success == true else {
                    self.errorMessage = "upload received success status is false"
                    return
                }

                self.uploadedImageUrlString = urlString
                self.imageUploaded = true
                print("upload link received, \(urlString)")

            })//sink ended
            
        }
    
    func getBase64Image(image: UIImage, complete: @escaping (String?) -> ()){
        let imageData = image.jpegData(compressionQuality: 0.01)
        let base64Jpeg = imageData?.base64EncodedString(options: .lineLength64Characters)
        complete(base64Jpeg)
    }
    
    func creatNewAlbum(){
        
            print("album id is first: \(self.albumId)")
            guard let accessToken = self.accessToken else {self.errorMessage = "Error creating album, no accessToken located";return}
            var request = URLRequest(url: URL(string: "https://api.imgur.com/3/album")!)
            request.addValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.httpMethod = "POST"
            let currentDateTime = Date()
            let formatter = DateFormatter()
            formatter.timeStyle = .medium
            formatter.dateStyle = .long
            let json : [String:String] = ["title":"Cataloger \(formatter.string(from: currentDateTime))","description":"automatically generated by cataloger on \(formatter.string(from: currentDateTime))","privacy":"hidden"]
            let jsonData = try? JSONSerialization.data(withJSONObject: json)
            request.httpBody = jsonData
            
            //self.pub
                let pub = URLSession.shared.dataTaskPublisher(for: request).print("test").tryMap { data,response -> Data in
                print("got data/response")
                guard let response = response as? HTTPURLResponse, response.statusCode == 200 else{
                    //error
                    //throw error here
                    print("newAlbum response is not 200")
                    self.errorMessage = "newAlbum response is not 200"
                    return data
                }
                return data
            }.decode(type: newAlbumResponse.self, decoder: JSONDecoder()).receive(on: RunLoop.main).eraseToAnyPublisher()
            
            self.sub = pub.sink(receiveCompletion: {completion in
                switch completion {
                case .finished:
                    //do something
                    print("newAlbumSink finished")
                    print("newAlbumId: \(self.albumId)")
                    break
                case .failure(let anError):
                    print("newAlbumSink received error \(anError)")
                    self.errorMessage = "creating album completed with failure"
                }
            }, receiveValue: { receivedValue in
                print("newAlbumSink receveid" )
                print("\(receivedValue)")
                guard let newAlbumResult : newAlbumResponse = receivedValue,
                      let success = newAlbumResult.success,
                      let data = newAlbumResult.data,
                      let albumId = data.id,
                      let deletehash = data.deletehash else {
                    self.errorMessage = "error parsing creating album received data "
                    return
                }
                
                guard success == true else {
                    self.errorMessage = "creating album received success status is false"
                    return
                }
                
                self.albumId = albumId
                
                print("new album id received, \(albumId)")
                UserDefaults.standard.setValue(albumId, forKey: "albumId")

                self.errorMessage = "**SUCCESS** creating new album with albumId \(albumId)"
//      
//                if let newAlbumResult : newAlbumResponse = receivedValue {
//                    guard let success = newAlbumResult.success else {
//                        self.errorMessage = "creating album return data doesnt have success field"
//                        return
//                    }
//                    if success == false {
//
//                    }
//
//                    self.albumId = newAlbumResult.data.id
//                    print("received albumId: \(self.albumId)")
//                } else {
//                    self.errorMessage = "error parsing creating new album result"
//                }
            })
            //print("album id is now: \(self.albumId)")
            
//            URLSession.shared.dataTask(with: request){
//                data, response, error in
//                if let error = error {
//                    self.errorMessage = error.localizedDescription
//                    return
//                }
//                guard let data = data else {
//                    self.errorMessage = "error creating album, response data is empty"
//                    return
//                }
//                print(String(data:data,encoding:.utf8)!)
//                let responseJSON = try? JSONSerialization.jsonObject(with: data, options: [])
//                if let responseJSON = responseJSON as? [String: Any],let dataPart = responseJSON["data"] as? [String:Any], let status = responseJSON["success"] as? Bool,let id = dataPart["id"] as? String{
//                    if status == false { self.errorMessage = "creating album response status is not succeed";print("creating album response status is not succeed");return}
//                    self.albumId = id
//                    print("Create album succeeded")
//                } else {
//                    //self.errorMessage = "creating album failed"
//                    print("parsing json data in creating album failed")
//                    return
//                }
//            }.resume()
    }
}
