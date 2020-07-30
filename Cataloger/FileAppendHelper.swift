//
//  FileAppendHelper.swift
//  Cataloger
//
//  Created by Maxim Lu on 7/23/20.
//  Copyright © 2020 Maxim Lu. All rights reserved.
//

import Foundation

extension String {
    func appendLineToURL(fileURL: URL) throws {
         try (self + "\n").appendToURL(fileURL: fileURL)
     }

     func appendToURL(fileURL: URL) throws {
         let data = self.data(using: String.Encoding.utf8)!
         try data.append(fileURL: fileURL)
     }
 }

 extension Data {
     func append(fileURL: URL) throws {
         if let fileHandle = FileHandle(forWritingAtPath: fileURL.path) {
             defer {
                 fileHandle.closeFile()
             }
             fileHandle.seekToEndOfFile()
             fileHandle.write(self)
         }
         else {
             try write(to: fileURL, options: .atomic)
         }
     }
 }
 //test
// do {
//     let dir: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).last! as URL
//     let url = dir.appendingPathComponent("logFile.txt")
//     try "Test \(Date())".appendLineToURL(fileURL: url as URL)
//     let result = try String(contentsOf: url as URL, encoding: String.Encoding.utf8)
// }
// catch {
//     print("Could not write to file")
// }
