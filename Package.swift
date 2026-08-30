// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MIDIHost",
    platforms: [.macOS(.v11)],
    products: [
        .executable(name: "MIDIHost", targets: ["MIDIHost"])
    ],
    targets: [
        .executableTarget(name: "MIDIHost")
    ]
)
