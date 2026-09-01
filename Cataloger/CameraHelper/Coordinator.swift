//
//  Coordinator.swift
//  Cataloger
//
//  Created by Maxim Lu on 7/23/20.
//  Copyright © 2020 Maxim Lu. All rights reserved.
//

import Foundation
import SwiftUI


class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {

  @Binding var isCoordinatorShown: Bool
  @Binding var imageInCoordinator: UIImage?

  init(isShown: Binding<Bool>, image: Binding<UIImage?>) {
    _isCoordinatorShown = isShown
    _imageInCoordinator = image
  }
/*
  func imagePickerController(_ picker: UIImagePickerController,
                didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
     guard let unwrapImage = info[UIImagePickerController.InfoKey.originalImage] as? UIImage else {
        print("*****unwrapping image failed")
        return
        
     }
    print( "***unwrapped image succeeded?")
     imageInCoordinator = unwrapImage
     isCoordinatorShown = false
  }*/
    func imagePickerController(_ picker: UIImagePickerController,
                              didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
        if let unwrapImage = info[.originalImage] as? UIImage {
            print("***unwrapped image succeeded?")
            imageInCoordinator = unwrapImage
        } else {
            print("*****unwrapping image failed. Info dictionary: \(info)")
            // Optionally present an alert or error to the user
        }
        isCoordinatorShown = false
    }

  func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
     isCoordinatorShown = false
  }
}
