import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

#if canImport(AppKit)
extension NSImage {
    public func jpegData(compressionQuality: CGFloat) -> Data? {
        let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        let jpegData = bitmapRep.representation(using: NSBitmapImageRep.FileType.jpeg, properties: [.compressionFactor: compressionQuality])
        return jpegData
    }
}
extension NSImage {
    /// Resize image while keeping the aspect ratio. Original image is not modified.
    /// - Parameters:
    ///   - width: A new width in pixels.
    ///   - height: A new height in pixels.
    /// - Returns: Resized image.
    public func resize(_ width: Int, _ height: Int) -> NSImage? {
        let newSize: NSSize
        let widthRatio  = Double(width) / self.size.width
        let heightRatio = Double(height) / self.size.height
        
        if widthRatio > heightRatio {
            newSize = NSSize(width: floor(self.size.width * widthRatio),
                             height: floor(self.size.height * widthRatio))
        } else {
            newSize = NSSize(width: floor(self.size.width * heightRatio),
                             height: floor(self.size.height * heightRatio))
        }
        let frame = NSRect(x: 0, y: 0, width: newSize.width, height: newSize.height)
        guard let representation = self.bestRepresentation(for: frame, context: nil, hints: nil) else {
            return nil
        }
        let image = NSImage(size: NSSize(width: newSize.width, height: newSize.height), flipped: false, drawingHandler: { (_) -> Bool in
            return representation.draw(in: frame)
        })
        
        return image
    }
}
#elseif canImport(UIKit)
import AVKit
extension UIImage {
    /// Resize image while keeping the aspect ratio. Original image is not modified.
    /// - Parameters:
    ///   - width: A new width in pixels.
    ///   - height: A new height in pixels.
    /// - Returns: Resized image.
    public func resize(_ width: Int, _ height: Int) -> UIImage {
        // Keep aspect ratio
        let maxSize = CGSize(width: width, height: height)
        
        let availableRect = AVFoundation.AVMakeRect(
            aspectRatio: self.size,
            insideRect: .init(origin: .zero, size: maxSize)
        )
        let targetSize = availableRect.size
        
        // Set scale of renderer so that 1pt == 1px
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        
        // Resize the image
        let resized = renderer.image { _ in
            self.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        
        return resized
    }
}
#endif
