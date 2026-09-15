import AppKit
import ImageIO
import UniformTypeIdentifiers
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let fm = FileManager.default
try fm.createDirectory(at: output.appendingPathComponent("Covers"), withIntermediateDirectories: true)
try fm.createDirectory(at: output.appendingPathComponent("Posters"), withIntermediateDirectories: true)
let inventory = try JSONDecoder().decode([[String: String]].self, from: Data(contentsOf: input.appendingPathComponent("inventory.json")))
var result: [[String: String]] = []
for (index, record) in inventory.enumerated() {
    try autoreleasepool {
        let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: record["preview"]!) as CFURL, nil)!
        let cover = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)!
        let poster = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 512] as CFDictionary)!
        let coverName = "\(index).png"
        let posterURL = output.appendingPathComponent("Posters/\(index).jpg")
        for (url, type, image) in [(output.appendingPathComponent("Covers/\(coverName)"), UTType.png, cover), (posterURL, UTType.jpeg, poster)] {
            let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw NSError(domain: "Fixture", code: 1) }
        }
        result.append(["title": record["title"]!, "preview": posterURL.path, "cover": coverName, "sourcePreview": record["preview"]!])
    }
}
try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("inventory.json"))
for name in ["fixture.mp4", "fixture.html"] { try fm.copyItem(at: input.appendingPathComponent(name), to: output.appendingPathComponent(name)) }
print("Prepared \(result.count) PNG covers and JPEG posters")
