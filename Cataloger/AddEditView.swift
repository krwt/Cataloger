//
//  AddEditView.swift
//  Cataloger
//
//  Created by Maxim Lu on 7/23/20.
//  Copyright © 2020 Maxim Lu. All rights reserved.
//

import SwiftUI

struct AddEditView: View {
    @ObservedObject var items : Items
    @Binding var isEditing : Bool
    @Binding var itemToAddEdit : Item
    @ObservedObject var imgurService : ImgurService
    //@State var name: String = ""
    //@State var desc: String = ""
    //@State var location: String = ""
    @State var itemImage : Image = Image(systemName: "photo")
    @Binding var selfIsShowing: Bool
    @Binding var sheetToShow : Bool
    @State var showCaptureImageView : Bool = false
    @State var capturedImage : UIImage?
    @State var errorMessage : String = ""
    @State var editingImage : Bool = false
    @State var showDeleteConformation : Bool = false
    //@State var isUploading : Bool = false
    //@State var imageUploaded : Bool = false
    var itemsList = itemSampleList
    
    
    var body: some View {
        ZStack{
        VStack(alignment: .leading){
            HStack{
                Button("Cancel") {
                    print("cancel tapped")
                    if self.isEditing == false{
                        self.itemToAddEdit = Item()
                    }
                    self.selfIsShowing = false
                    self.sheetToShow = false
                }.padding(.leading, /*@START_MENU_TOKEN@*/10/*@END_MENU_TOKEN@*/)
                Spacer()
                if self.isEditing && (showDeleteConformation == false){
                    Button {
                        showDeleteConformation.toggle()
                    } label: {
                        Text("Delete").foregroundColor(.red)
                    }
                }
                
                if self.isEditing && self.showDeleteConformation{
                    Button {
                        self.itemToAddEdit.name = "removeEntry"
                        self.selfIsShowing = false
                        self.sheetToShow = false
                    } label: {
                        Text("**I AM SURE**").foregroundColor(.red)
                    }

                }
                Spacer()
                Button("Add/Save") {
                    print("Add/Save Button tapped tapped")
                    if self.capturedImage != nil && !imgurService.imageUploaded{
                        //uploading in progress, cancel action
                        self.errorMessage = "uploading in progress please wait"
                        return
                        
                    }
                    
                    if self.isEditing == false {
                        //Adding item
                        print("adding one entry")
                        print(" name of new item to add : \(itemToAddEdit.name)")
                        if itemToAddEdit.name == "" {
                            print("empty entry discarded ")
                            return
                        }
                        
                        itemToAddEdit.name = itemToAddEdit.name.replacingOccurrences(of: ",", with: ".")
                        itemToAddEdit.description = itemToAddEdit.description.replacingOccurrences(of: ",", with: ".")
                        itemToAddEdit.fullLocation = itemToAddEdit.fullLocation.replacingOccurrences(of: ",", with: ".")
                        
                        itemToAddEdit.imgUrl = URL(string: imgurService.uploadedImageUrlString)
                        imgurService.uploadedImageUrlString = ""
                        itemToAddEdit.id = items.id
                        itemToAddEdit.uuid = UUID().uuidString
                        itemToAddEdit.description = itemToAddEdit.description.replacingOccurrences(of: "\n", with: "||")
                        items.fullList.append(itemToAddEdit)
                        items.id += 1
                        items.saveHEICtoiCloud(image: capturedImage, uuid: itemToAddEdit.uuid)
                        items.update()
                        itemToAddEdit = Item()
                        capturedImage = nil
                    } else {
                        print("edit mode ended")
                        if let url = URL(string: imgurService.uploadedImageUrlString) {
                            itemToAddEdit.imgUrl = url
                            imgurService.uploadedImageUrlString = ""
                        }
                        self.selfIsShowing = false
                        self.sheetToShow = false
                    }
                }.padding(.trailing, /*@START_MENU_TOKEN@*/10/*@END_MENU_TOKEN@*/)
            }.padding(.bottom, 20)
            
            if isEditing {
                Text("Name").foregroundColor(.gray).font(.caption)
                TextField(itemToAddEdit.name, text: $itemToAddEdit.name).textFieldStyle(RoundedBorderTextFieldStyle())
                Text("Description").foregroundColor(.gray).font(.caption)
                //TextField(itemSampleList[0].description.replacingOccurrences(of: ".", with: "\n"), text: $desc)
                #if targetEnvironment(macCatalyst)
                TextField(itemToAddEdit.description, text: $itemToAddEdit.description)
                #else
                TextEditor(text: $itemToAddEdit.description).frame(height: 100, alignment: .center)
                #endif
                Text("container").foregroundColor(.gray).font(.caption)
                TextField(itemToAddEdit.fullLocation, text: $itemToAddEdit.fullLocation).textFieldStyle(RoundedBorderTextFieldStyle())
                Text("image").foregroundColor(.gray)
                if !self.editingImage, let imageUrl = itemToAddEdit.imgUrl {
                    URLImageView(imageUrlString: imageUrl.absoluteString)
                    Button(action: {
                        self.editingImage.toggle()
                    }, label: {
                        Text("\nChange Image\n").font(.title)
                    })
                    #if targetEnvironment(macCatalyst)
                    if let urlString = itemToAddEdit.imgUrl?.absoluteString {
                        Text(urlString).foregroundColor(.blue)
                    }
                    #else
                    if let urlString = itemToAddEdit.imgUrl?.absoluteString, let url = itemToAddEdit.imgUrl{
                        Link(urlString, destination: url)
                    }
                    #endif
                    
                } else {
                    ZStack{
                        if let image = Image(uiImage:capturedImage ?? UIImage(systemName: "photo")!)  {
                                image.resizable().scaledToFit().gesture(TapGesture().onEnded({ (_) in
                                        showCaptureImageView.toggle()
                                    imgurService.imageUploaded = false
                                    }))
                            }
                        if let capturedImage = capturedImage, let _ =  Image(uiImage: capturedImage) {
                            Button(action: {
                                if imgurService.imageUploaded || imgurService.uploading{
                                    return
                                } else {
                                    //upload image
                                    print("upload button tapped, uploading")
                                    imgurService.uploading = true
                                    imgurService.uploadImage(image: capturedImage, name: itemToAddEdit.name+"@"+itemToAddEdit.uuid, description: itemToAddEdit.description+"@"+itemToAddEdit.fullLocation)
                                    //self.saveHEICtoiCloud(image: capturedImage, uuid: UUID().uuidString)
                                }
                            }, label: {
                                if imgurService.imageUploaded {
                                    Image(systemName: "checkmark").font(.title).foregroundColor(.green)
                                } else {
                                    if imgurService.uploading {
                                        Text("Uploading").font(.title)
                                    } else {
                                    Text("\nUpload\n").font(.title).opacity(1)
                                    }
                                }
                            }).opacity(1).background(Color.white)
                        }
                    }//end Zstack for image section
                }
            } else {
                Text("Name").foregroundColor(.gray).font(.caption)
                TextField("Name", text: $itemToAddEdit.name).textFieldStyle(RoundedBorderTextFieldStyle())
                Text("Description").foregroundColor(.gray).font(.caption)
                #if targetEnvironment(macCatalyst)
                TextField(itemToAddEdit.description, text: $itemToAddEdit.description)
                #else
                TextEditor(text: $itemToAddEdit.description).frame(height:100).border(Color.gray, width: /*@START_MENU_TOKEN@*/1/*@END_MENU_TOKEN@*/)
                #endif
                Text("container").foregroundColor(.gray).font(.caption)
                TextField("Container", text: $itemToAddEdit.fullLocation).textFieldStyle(RoundedBorderTextFieldStyle())
                Text("image").foregroundColor(.gray)
                ZStack{
                    if let image = Image(uiImage:capturedImage ?? UIImage(systemName: "photo")!)  {
                            image.resizable().scaledToFit().gesture(TapGesture().onEnded({ (_) in
                                    showCaptureImageView.toggle()
                                imgurService.imageUploaded = false
                                }))
                        }
                    if let capturedImage = capturedImage, let _ =  Image(uiImage: capturedImage) {
                        Button(action: {
                            if imgurService.imageUploaded || imgurService.uploading{
                                return
                            } else {
                                //upload image
                                print("upload button tapped, uploading")
                                imgurService.uploading = true
                                imgurService.uploadImage(image: capturedImage, name: itemToAddEdit.name+"@"+itemToAddEdit.uuid, description: itemToAddEdit.description+"@"+itemToAddEdit.fullLocation)
                                //self.saveHEICtoiCloud(image: capturedImage, uuid: UUID().uuidString)
                            }
                        }, label: {
                            if imgurService.imageUploaded {
                                Image(systemName: "checkmark").font(.title).foregroundColor(.green)
                            } else {
                                if imgurService.uploading {
                                    Text("Uploading").font(.title)
                                } else {
                                Text("\nUpload\n").font(.title).opacity(1)
                                }
                            }
                        }).opacity(1).background(Color.white)
                    }
                }//end Zstack for image section
            }
            
            
            //Spacer()
        }.padding(.all, /*@START_MENU_TOKEN@*/10/*@END_MENU_TOKEN@*/)//main VStack in ZStack End
            
            if (showCaptureImageView) {
                CaptureImageView(isShown: $showCaptureImageView, image: $capturedImage
                )
            }
            
            if imgurService.errorMessage.isEmpty == false {
                Text(imgurService.errorMessage).font(.title).foregroundColor(.red).gesture(TapGesture().onEnded({ _ in
                    imgurService.errorMessage = ""
                }))
            }
            if !self.errorMessage.isEmpty {
                Text(self.errorMessage).font(.title).foregroundColor(.red).gesture(TapGesture().onEnded({_ in
                    self.errorMessage = ""
                }))
            }
        }//Whole ZStack end
    }//View end
    
   
    
}//class end

struct AddEditView_Previews: PreviewProvider {
    static var previews: some View {
        //AddEditView(isEditing: true,name: itemSampleList[0].name,desc: itemSampleList[0].description,location: itemSampleList[0].location)
        AddEditView(items: Items(),isEditing: .constant(false), itemToAddEdit: .constant(Item()), imgurService: ImgurService(),selfIsShowing: .constant(true),sheetToShow : .constant(true))
    }
}
