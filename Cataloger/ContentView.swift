//
//  ContentView.swift
//  Cataloger
//
//  Created by Maxim Lu on 7/16/20.
//  Copyright © 2020 Maxim Lu. All rights reserved.
//

import SwiftUI

//data should be in data.mcs
//then duplicated to data.csv to avoid accidental modification when viewed with other apps
@available(iOS 17.0, *)
struct ContentView: View {
    @State var imgurButtonText : String = "Imgur"
    @ObservedObject var imgurService : ImgurService
    @ObservedObject var items: Items
    @State var searchTerm : String = ""
    @State var showAlert : Bool = false
    @State var showAddEditSheet = false
    @State var actionIsEditing = false
    @State var sheetToShow = false
    @State var selectedItem : Item = Item()
    @State var showImgurButtons  = false
    @State var previewImageUrlString = ""
    @State var showQRScanner : Bool = false
    @State var FoundQRString : String = ""
    @State var addModeContainerMemory : String = "TBD" //remember last used container when in sequence adding mode
    @FocusState var searchBarFocused:Bool
    @FocusState var addButtonFocused:Bool
    var body: some View {
        ZStack{
            
        VStack{
            ZStack{
                if showQRScanner {
                    QRScannerView().found(r: { (scannedString) in
                        showQRScanner = false
                        searchTerm = scannedString
                    }).torchLight(isOn: false).interval(delay: 1.0)}
                    
                if showQRScanner{
                    Button {
                        showQRScanner = false
                    } label: {
                        Text("Cancel").foregroundColor(.red).background(Color.white).font(.largeTitle)
                    }
                }
            }
            HStack{
                VStack{
//                    Button("Imgur") {
//                        print("imgur button tapped" )
//                    }.padding(.leading, /*@START_MENU_TOKEN@*/10/*@END_MENU_TOKEN@*/).padding(.trailing, 5)
                    #if targetEnvironment(macCatalyst)
                    #else
                    if imgurService.loggedIn == false {
                        Link("Imgur",destination: imgurService.requestUrl!)
                    } else {
                        Button("stat") {
                            showImgurButtons.toggle()
                        }
                    }
                    #endif
                    
                    Button("Reload"){
                        items.reloadData()
                    }.padding(.leading, /*@START_MENU_TOKEN@*/10/*@END_MENU_TOKEN@*/).padding(.trailing, 5)
                    
                }
                ZStack(alignment: .trailing){
                    
                    #if os(macOS)
                    TextField("Search name: container: macos", text: $searchTerm).background(Color.gray.opacity(0.1).font(.title)).focused($searchBarFocused).border(Color.blue, width: searchBarFocused ? 2 : 0).onKeyPress(.escape) {
                        print("escape detected")
                        searchTerm = ""
                        return .handled
                    }.onExitCommand(perform: {
                        print("exit command detected")
                    })
                    #else
                    TextField("Search name: container: (down to clear)", text: $searchTerm).background(Color.gray.opacity(0.1).font(.title)).focused($searchBarFocused).border(Color.blue, width: searchBarFocused ? 2 : 0).onKeyPress(.downArrow) {
                        DispatchQueue.main.async {
                            print("downarrow detected")
                            searchTerm = ""
                        }
                        return .handled
                    }
                    #endif
                    if items.dataLoaded == false {
                        Text("Loading Data.........").font(.title).background(Color.blue).opacity(1)
                    }
                    if self.searchTerm.isEmpty == false{
                        Button() {
                            self.searchTerm = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill").font(Font.system(size: 26))
                        }.padding(.trailing,5).keyboardShortcut(.cancelAction)
                    } else {
                        Button {
                            self.showQRScanner = true
                        } label: {
                            Image(systemName: "camera").font(Font.system(size:26))
                        }

                    }
                }
                    
                Button("Add"){
                    selectedItem = Item()
                    self.sheetToShow = true
                    self.showAddEditSheet = true
                    self.actionIsEditing = false
                }.padding(.trailing, /*@START_MENU_TOKEN@*/10/*@END_MENU_TOKEN@*/).focusable().focused($addButtonFocused)
            }.padding().onAppear(perform: {
                addButtonFocused = false
                searchBarFocused = true
            })
            List{
                //reversed so newest show on top
                ForEach(items.fullList.reversed()){
                    each in
                    if searchTerm == "" {
                        HStack{
                            /*
                            ItemRow(item: each).gesture(TapGesture().onEnded({ _ in
                                    self.actionIsEditing = true
                                    print("editing mode")
                                    self.selectedItem = each
                                    print(self.selectedItem)
                                    self.sheetToShow = true
                                    self.showAddEditSheet = true
                            }))
                            */
                            //Spacer()
                            HStack{
                                ItemRow(item: each)
                                Spacer()
                            }.contentShape(Rectangle()).gesture(TapGesture().onEnded({ _ in
                                self.actionIsEditing = true
                                print("editing mode")
                                self.selectedItem = each
                                print(self.selectedItem)
                                self.sheetToShow = true
                                self.showAddEditSheet = true
                            }))
                            
                            if let imageUrl = each.imgUrl {
                                Image(systemName: "photo").gesture(TapGesture().onEnded({ _ in
                                    self.previewImageUrlString = imageUrl.absoluteString
                                    print("PreviewButtonTapped")
                                })).foregroundColor(.green).frame(maxWidth:40)//.border(Color.blue, width: 1)
                            }
                            /*
                            if let imageUrl = each.imgUrl {
                                Button(action: {
                                    self.previewImageUrlString = imageUrl.absoluteString
                                    print("PreviewButtonTapped")
                                }, label: {
                                    Image(systemName: "photo")
                                }).foregroundColor(.green).frame(maxWidth:40).border(Color.blue, width: 1)
                            }*/
                        }
                    } else {
                        if (!(searchTerm.lowercased().contains("name:")) && (each.name.lowercased().contains(searchTerm.lowercased()) || each.description.lowercased().contains(searchTerm.lowercased()))) || (
                            each.fullLocation.lowercased().contains(searchTerm.lowercased().replacingOccurrences(of: "container:", with: ""))
                        ) || ( each.name.lowercased().contains(searchTerm.lowercased().replacingOccurrences(of:"name:",with:"").lowercased())) || (each.uuidForLabel.contains(searchTerm.uppercased()))     {
                            HStack{
                                ItemRow(item: each).gesture(TapGesture().onEnded({ _ in
                                self.actionIsEditing = true
                                print("editing mode")
                                self.selectedItem = each
                                print(self.selectedItem)
                                self.sheetToShow = true
                                self.showAddEditSheet = true
                                }))
                                Spacer()
                                if let imageUrl = each.imgUrl {
                                    Button(action: {
                                        self.previewImageUrlString = imageUrl.absoluteString
                                        print("PreviewButtonTapped")
                                    }, label: {
                                        Image(systemName: "photo")
                                    })
                                }
                            }
                        }
                    }
                    
                }
            }
        }.sheet(isPresented: $sheetToShow, onDismiss: {
            if self.showAlert {
                sheetToShow = true
                return
            } else {
                print("sheet dimissed ")
                print(imgurService.accessToken)
                print(imgurService.lastLogIn)
                print(imgurService.albumId)
                print("url is \(selectedItem.imgUrl?.absoluteString ?? "no url avilable")")
                self.sheetToShow = false
                self.showAlert = false
                self.showAddEditSheet = false
                if actionIsEditing {
                    print("sheet dismissed was in edit mode")
                    if imgurService.uploadedImageUrlString != ""{
                        selectedItem.imgUrl = URL(string: imgurService.uploadedImageUrlString)
                        imgurService.uploadedImageUrlString = ""
                    }
                    
                    if selectedItem.name == "removeEntry" {
                        //delete item
                        if !selectedItem.uuid.isEmpty{
                            let fileName = selectedItem.uuid+".heic"
                            items.removeHEICFromiCloud(fileName: fileName)
                        }
                        items.fullList.remove(at: selectedItem.id)
                        print("Item removed at \(selectedItem.id)")
                        items.save()
                        return
                    }
                    
                    if let idx = items.fullList.firstIndex(where: { $0.id == selectedItem.id }) {
                        if selectedItem != items.fullList[idx] {
                                print("edit did change entry")
                            selectedItem.description = selectedItem.description.replacingOccurrences(of: "\n", with: "||")
                            selectedItem.description = selectedItem.description.replacingOccurrences(of: ",", with: ".")
                            selectedItem.name = selectedItem.name.replacingOccurrences(of: ",", with: ".")
                            selectedItem.fullLocation = selectedItem.fullLocation.replacingOccurrences(of: ",", with: ".")
                        
                            items.fullList[idx] = selectedItem
                            items.save()
                        } else {print("edit did not change entry" )}
                    } else {
                        print("Selected item not found in fullList; cannot compare or update.")
                    }
                } else {
                    if selectedItem.name == "" {
                        print("empty entry discarded ")
                        return
                    }
                    print("adding new entry")
                    if imgurService.uploadedImageUrlString != ""{
                        selectedItem.imgUrl = URL(string: imgurService.uploadedImageUrlString)
                        imgurService.uploadedImageUrlString = ""
                    }
                    items.id += 1
                    selectedItem.id = items.id
                    selectedItem.description = selectedItem.description.replacingOccurrences(of: "\n", with: "||")
                    selectedItem.description = selectedItem.description.replacingOccurrences(of: ",", with: ".")
                    selectedItem.fullLocation = selectedItem.fullLocation.replacingOccurrences(of: ",", with: ".")
                    selectedItem.name = selectedItem.name.replacingOccurrences(of: ",", with: ".")
                    items.fullList.append(selectedItem)
                    items.update()
                    print("current list : \(items.fullList)")
                    items.reloadData()
                }
            }
        }) {//onDismiss end sheet start
            
            if showAlert {
                iCloudAlert(showAlert: $showAlert,sheetToShow: $sheetToShow)
            }
             //why?????? comment out for testing
                else {
                AddEditView(items:items, isEditing: $actionIsEditing, itemToAddEdit: $selectedItem, containerNameforAdding: $addModeContainerMemory, imgurService: imgurService, selfIsShowing: $showAddEditSheet, sheetToShow: $sheetToShow).environmentObject(items).environmentObject(imgurService)
             
                }//sheet end
             
            
        }//end primary VStack in ZStack
            VStack{
            if !self.imgurService.errorMessage.isEmpty {
                //Text("Error Message Received").font(.title).foregroundColor(.red)
                Text(self.imgurService.errorMessage).font(.title).foregroundColor(.red).gesture(TapGesture().onEnded({_ in
                                                                                                                        self.imgurService.errorMessage = ""}))
            }
                if !self.items.errorMessage.isEmpty {
                    //Text("Error Message Received").font(.title).foregroundColor(.red)
                    Text(self.items.errorMessage).font(.title).foregroundColor(.red).gesture(TapGesture().onEnded({_ in
                                                                                                                            self.items.errorMessage = ""}))
                }
                #if targetEnvironment(macCatalyst)
                #else
                if self.showImgurButtons{
                    Link("logInImgur",destination: imgurService.requestUrl!)
                    if let username = imgurService.userName {
                        Text("imgur username: \(username)")
                    } else {
                        Text("imgur username: none")
                    }
                    if let albumId = imgurService.albumId{
                        Text("imgur albumId: \(albumId)")
                    } else {
                        Text("imgur albumId: None")
                    }
                    Button("New Album") {
                        imgurService.creatNewAlbum()
                    }
                } //end if showimgurbuttons
                #endif
                if !self.previewImageUrlString.isEmpty {
                    //show image preview view in Zstack
                    URLImageView(imageUrlString: previewImageUrlString).gesture(TapGesture().onEnded({ (_) in
                        self.previewImageUrlString = ""
                    }))
                }
            } //end Main Zstack's VStack (error / imgur stat zstack
            
            
        }.onAppear{
            if items.fullList.isEmpty {
                sheetToShow = true
                showAlert = true
            }
        }//end ZStack
    }
}
@available(iOS 17.0, *)
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(imgurService: ImgurService(),items: Items())
    }
}
