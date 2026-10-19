// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "SelectCopy",
  platforms: [.macOS(.v13)],
  products: [
    .executable(name: "SelectCopy", targets: ["SelectCopyApp"]),
    .executable(name: "select_copy", targets: ["SelectCopyCLI"]),
  ],
  targets: [
    .target(name: "SelectCopyCore"),
    .executableTarget(name: "SelectCopyApp", dependencies: ["SelectCopyCore"]),
    .executableTarget(name: "SelectCopyCLI", dependencies: ["SelectCopyCore"]),
    .testTarget(name: "SelectCopyCoreTests", dependencies: ["SelectCopyCore", "SelectCopyApp"]),
  ]
)
