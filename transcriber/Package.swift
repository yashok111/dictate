// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Transcriber",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Transcriber", targets: ["TranscriberApp"]),
               .executable(name: "transcriber-diarizer", targets: ["CommunityDiarizer"])],
    dependencies: [.package(url: "https://github.com/FluidInference/FluidAudio.git",
        revision: "04e363c29d9a754022d602d6fe1468ab80a0f705", traits: [])],
    targets: [
        .executableTarget(name: "CommunityDiarizer", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]),
        .target(name: "CTranscriber", path: "core", publicHeadersPath: "include"),
        .target(name: "TranscriptKit", dependencies: ["CTranscriber"]),
        .executableTarget(name: "TranscriberApp", dependencies: ["TranscriptKit"])
    ],
    swiftLanguageModes: [.v5],
    cxxLanguageStandard: .cxx17
)
