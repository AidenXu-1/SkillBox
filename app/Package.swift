// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SkillBox",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SkillBoxCore", targets: ["SkillBoxCore"]),
        .executable(name: "SkillBox", targets: ["SkillBoxApp"]),
        .executable(name: "SkillBoxDiagnostics", targets: ["SkillBoxDiagnostics"]),
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        .target(name: "SkillBoxCore", exclude: ["Resources"]),
        .executableTarget(
            name: "SkillBoxApp",
            dependencies: ["SkillBoxCore", .product(name: "Sparkle", package: "Sparkle")],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .executableTarget(
            name: "SkillBoxDiagnostics",
            dependencies: ["SkillBoxCore"]
        ),
        .testTarget(
            name: "SkillBoxCoreTests",
            dependencies: ["SkillBoxCore", "SkillBoxApp"]
        ),
    ]
)
