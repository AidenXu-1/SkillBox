import AppKit
import Foundation
import Vision

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: AppIconIntegrationCheck <app-path>\n", stderr)
    exit(2)
}

let appPath = CommandLine.arguments[1]

func featurePrint(for image: NSImage) throws -> VNFeaturePrintObservation {
    var proposedRect = NSRect(origin: .zero, size: image.size)
    guard let cgImage = image.cgImage(
        forProposedRect: &proposedRect,
        context: nil,
        hints: [.interpolation: NSImageInterpolation.high]
    ) else {
        throw NSError(domain: "SkillBoxAppIconCheck", code: 1)
    }

    let request = VNGenerateImageFeaturePrintRequest()
    try VNImageRequestHandler(cgImage: cgImage).perform([request])
    guard let observation = request.results?.first as? VNFeaturePrintObservation else {
        throw NSError(domain: "SkillBoxAppIconCheck", code: 2)
    }
    return observation
}

guard let bundle = Bundle(path: appPath),
      let configuredIconFile = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String else {
    fputs("The app bundle does not declare CFBundleIconFile.\n", stderr)
    exit(4)
}

let iconFilename = configuredIconFile.hasSuffix(".icns")
    ? configuredIconFile
    : configuredIconFile + ".icns"
let iconURL = URL(fileURLWithPath: appPath)
    .appendingPathComponent("Contents/Resources")
    .appendingPathComponent(iconFilename)

guard let configuredIcon = NSImage(contentsOf: iconURL) else {
    fputs("The configured app icon could not be loaded.\n", stderr)
    exit(5)
}

let resolvedIcon = NSWorkspace.shared.icon(forFile: appPath)
let resolvedFeaturePrint = try featurePrint(for: resolvedIcon)
let configuredFeaturePrint = try featurePrint(for: configuredIcon)
var featureDistance: Float = 0
try resolvedFeaturePrint.computeDistance(&featureDistance, to: configuredFeaturePrint)
print("featureDistance=\(featureDistance)")

guard featureDistance < 0.8 else {
    fputs("macOS resolved an icon that does not match the configured SkillBox icon.\n", stderr)
    exit(1)
}

print("macOS resolved the configured SkillBox application icon.")
