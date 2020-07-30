//
//  AppDelegate.swift
//  Cataloger
//
//  Created by Maxim Lu on 7/16/20.
//  Copyright © 2020 Maxim Lu. All rights reserved.
//

import UIKit

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {

    func testicloudDrive(){
        let rootDir = FileManager.default.url(forUbiquityContainerIdentifier: nil)!
        print(FileManager.default.url(forUbiquityContainerIdentifier: nil) ?? "No url found")
        //only files in documents subdirectory will show in folder in icloud drive
        var objctrue: ObjCBool = true
        let documentsURL = FileManager.default.url(forUbiquityContainerIdentifier: nil)!.appendingPathComponent("Documents", isDirectory: true)
        if FileManager.default.fileExists(atPath: documentsURL.path, isDirectory: &objctrue) == false {
            do {
                try FileManager.default.createDirectory(at: documentsURL, withIntermediateDirectories: false, attributes: nil)
            } catch{
                print("error crreating documents dir: \(error)")
            }
        }
        let fileName = documentsURL.appendingPathComponent("test.txt", isDirectory: false)
        if FileManager.default.fileExists(atPath: fileName.path)==false {
            print("creating test.txt")
            FileManager.default.createFile(atPath: fileName.path, contents: nil, attributes: nil)
        }
        let currentDateTime = Date()
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .long
        
        let str = "this is to test icloud file storage capabilities " + formatter.string(from: currentDateTime)
        
        do{
            print("writing to file: \(fileName)")
            try str.write(to: fileName, atomically: true, encoding: .utf8)
        } catch {
            print("something is wrong in writing to file")
            print(error)
        }
        do {
            let fileUrls = try FileManager.default.contentsOfDirectory(at: documentsURL,includingPropertiesForKeys: nil)
            print(" files in current icloud folder: ")
            print(fileUrls)
            }
        catch {
            print("error getting files in current icloud folder")
            print(error)
        }
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Override point for customization after application launch.
        //testicloudDrive()
        return true
    }

    // MARK: UISceneSession Lifecycle

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        // Called when a new scene session is being created.
        // Use this method to select a configuration to create the new scene with.
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }

    func application(_ application: UIApplication, didDiscardSceneSessions sceneSessions: Set<UISceneSession>) {
        // Called when the user discards a scene session.
        // If any sessions were discarded while the application was not running, this will be called shortly after application:didFinishLaunchingWithOptions.
        // Use this method to release any resources that were specific to the discarded scenes, as they will not return.
    }


}

