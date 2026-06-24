// swift-tools-version: 6.0
import Foundation
import PackageDescription

let libSearchPath = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("Sources/CppBridge")
    .path

let package = Package(
    name: "Zraw2DNG",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "Zraw2DNG", targets: ["Zraw2DNG"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "CppBridge",
            dependencies: [],
            path: "Sources/CppBridge",
            publicHeadersPath: "include",
            cxxSettings: [
                .unsafeFlags(["-I/opt/homebrew/opt/openssl@3/include"]),
            ],
            linkerSettings: [
                .unsafeFlags(["-L/opt/homebrew/opt/openssl@3/lib", "-L\(libSearchPath)"]),
                .linkedLibrary("zraw"),
                .linkedLibrary("crypto"),
            ]
        ),
        .executableTarget(
            name: "Zraw2DNG",
            dependencies: ["CppBridge"]
        )
    ],
    cLanguageStandard: .c11,
    cxxLanguageStandard: .cxx11
)
