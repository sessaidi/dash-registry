// swift-tools-version: 6.2
import PackageDescription

/// On-device speech for recorded meetings: transcription (Parakeet) and who-spoke-when with
/// voiceprints (pyannote), through FluidAudio. Only the Diarizer trait: FluidAudio's text to
/// speech and its prebuilt text-normalisation framework stay out of the plugin.
let package = Package(
    name: "MeetingSpeech",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MeetingSpeech", targets: ["MeetingSpeech"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.4", traits: ["Diarizer"]),
    ],
    targets: [
        .target(name: "MeetingSpeech", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]),
    ]
)
