
import Foundation
import PDFKit
import CoreGraphics
import CoreImage
import UIKit

public struct LabelGenerator {
    
    // Inches to Points (PDFKit utilizes points: 1 inch = 72 points)
    private static func inch(_ value: CGFloat) -> CGFloat {
        return value * 72.0
    }
    
    // CoreImage QR Code Engine with crisp, high-resolution scaling
    private static func generateQRCode(from string: String, targetSizeInPoints: CGFloat) -> CGImage? {
        guard let data = string.data(using: .ascii),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel") // Medium error correction
        
        guard let ciImage = filter.outputImage else { return nil }
        
        let extent = ciImage.extent.size
        guard extent.width > 0 else { return nil }
        
        // Scale factor multiplied by 5.0 to achieve high-resolution print density
        let desiredDeviceScale = (targetSizeInPoints / extent.width) * 5.0
        let transform = CGAffineTransform(scaleX: desiredDeviceScale, y: desiredDeviceScale)
        let transformedImage = ciImage.transformed(by: transform)
        
        let context = CIContext(options: [CIContextOption.useSoftwareRenderer: false])
        return context.createCGImage(transformedImage, from: transformedImage.extent)
    }
    
    /// Generates a complete PDF document matching the exact 4x6 label matrix specifications.
    /// - Parameters:
    ///   - totalPages: Total number of 20-label pages to create.
    ///   - logoImageName: The string name matching an image asset inside your app's Asset Catalog (Assets.xcassets)
    /// - Returns: A functional PDFDocument ready for previewing, sharing, or AirPrint.
    public static func generateLabels(totalPages: Int, logoImageName: String? = nil) -> PDFDocument {
        let pdfDocument = PDFDocument()
        let pageBounds = CGRect(x: 0, y: 0, width: inch(4), height: inch(6))
        
        // Layout metrics
        let xm: CGFloat = 0.5
        let ym: CGFloat = 0.38
        let xg: CGFloat = 0.0
        let yg: CGFloat = 0.06
        let qrsize: CGFloat = 0.6
        let labelWidth: CGFloat = 0.75
        let labelHeight: CGFloat = 1.0
        let logosize: CGFloat = 0.2
        let greenRectPaddingWidth: CGFloat = 0.06
        let greenRectPaddingHeight: CGFloat = 0.06
        
        let catalogerGreen = CGColor(red: 164/255, green: 222/255, blue: 2/255, alpha: 1.0)
        let black = CGColor(red: 0, green: 0, blue: 0, alpha: 1.0)
        let white = CGColor(red: 1, green: 1, blue: 1, alpha: 1.0)
        
        // iOS Native Image Fetching from Assets.xcassets
        var logoCGImage: CGImage? = nil
        if let logoName = logoImageName, let uiImage = UIImage(named: logoName) {
            logoCGImage = uiImage.cgImage
        }
        
        for _ in 0..<totalPages {
            let renderer = iOSPDFPageRenderer(bounds: pageBounds) { context in
                
                // Grid loop: 5 rows, 4 columns (20 labels per page)
                for y in 0..<5 {
                    for x in 0..<4 {
                        let xc = xm + CGFloat(x) * xg + CGFloat(x) * labelWidth
                        let yc = ym + CGFloat(y) * yg + CGFloat(y) * labelHeight
                        
                        // --- Draw Green Background Rounded Rectangle ---
                        context.setFillColor(catalogerGreen)
                        let greenRect = CGRect(
                            x: inch(xc - greenRectPaddingWidth),
                            y: inch(yc - greenRectPaddingHeight),
                            width: inch(labelWidth + 2 * greenRectPaddingWidth),
                            height: inch(labelHeight + 2 * greenRectPaddingHeight)
                        )
                        context.addPath(CGPath(roundedRect: greenRect, cornerWidth: 4, cornerHeight: 4, transform: nil))
                        context.fillPath()
                        
                        // Generate dynamic tracking identifiers
                        let uidString = UUID().uuidString.lowercased()
                        let snippet = uidString.split(separator: "-").first?.uppercased() ?? ""
                        
                        // --- Draw White Inner Square Background for QR ---
                        context.setFillColor(white)
                        let whiteRect = CGRect(
                            x: inch(xc + (labelWidth - qrsize) / 2 - 0.015),
                            y: inch(yc + (labelWidth - qrsize) / 3.3 - 0.015),
                            width: inch(qrsize + 0.03),
                            height: inch(qrsize + 0.03)
                        )
                        context.addPath(CGPath(roundedRect: whiteRect, cornerWidth: 4, cornerHeight: 4, transform: nil))
                        context.fillPath()
                        
                        // --- Draw QR Code ---
                        let targetQRSizePoints = inch(qrsize)
                        if let qrCodeImage = generateQRCode(from: uidString, targetSizeInPoints: targetQRSizePoints) {
                            let qrRect = CGRect(
                                x: inch(xc + (labelWidth - qrsize) / 2),
                                y: inch(yc + (labelWidth - qrsize) / 3.3),
                                width: targetQRSizePoints,
                                height: targetQRSizePoints
                            )
                            
                            context.saveGState()
                            context.setShouldAntialias(false)
                            context.interpolationQuality = .none
                            context.draw(qrCodeImage, in: qrRect)
                            context.restoreGState()
                        }
                        
                        // --- Draw Brand Logo Image Asset ---
                        if let logo = logoCGImage {
                            let logoRect = CGRect(
                                x: inch(xc + (labelWidth - logosize) / 2),
                                y: inch(yc + (qrsize + (labelHeight - qrsize) / 2.2)),
                                width: inch(logosize),
                                height: inch(logosize)
                            )
                            context.draw(logo, in: logoRect)
                        }
                        
                        // --- Draw Text Snippet ---
                        let font = UIFont.systemFont(ofSize: 8, weight: .medium)
                        let attributes: [NSAttributedString.Key: Any] = [
                            .font: font,
                            .foregroundColor: UIColor.black
                        ]
                        let attributedString = NSAttributedString(string: snippet, attributes: attributes)
                        let line = CTLineCreateWithAttributedString(attributedString)
                        let lineWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
                        
                        let textX = inch(xc + labelWidth / 2) - CGFloat(lineWidth / 2)
                        let textY = inch(yc + (qrsize + (labelHeight - qrsize) * 0.24))
                        
                        context.textPosition = CGPoint(x: textX, y: textY)
                        CTLineDraw(line, context)
                    }
                }
            }
            
            pdfDocument.insert(renderer, at: pdfDocument.pageCount)
        }
        
        return pdfDocument
    }
}

// Custom programmatic layout canvas mapping for iOS PDFKit framework
final class iOSPDFPageRenderer: PDFPage {
    private let drawClosure: (CGContext) -> Void
    private let customBounds: CGRect
    
    init(bounds: CGRect, drawing: @escaping (CGContext) -> Void) {
        self.customBounds = bounds
        self.drawClosure = drawing
        super.init()
    }
    
    override func bounds(for box: PDFDisplayBox) -> CGRect {
        return customBounds
    }
    
    override func draw(with box: PDFDisplayBox, to context: CGContext) {
        super.draw(with: box, to: context)
        drawClosure(context)
    }
}
