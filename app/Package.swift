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
    targets: [
        .target(name: "SkillBoxCore"),
        .executableTarget(
            name: "SkillBoxApp",
            dependencies: ["SkillBoxCore"]
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
