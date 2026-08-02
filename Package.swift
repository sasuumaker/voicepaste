// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "VoicePaste",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "VoicePasteCore"),
        .executableTarget(
            name: "VoicePaste",
            dependencies: ["VoicePasteCore"]
        ),
        // XCTest非依存のテストランナー（この環境はCLTのみでXCTestが無いため）
        // 実行: swift run VoicePasteTests
        .executableTarget(
            name: "VoicePasteTests",
            dependencies: ["VoicePasteCore"]
        ),
        // 実Groq APIを叩くE2Eテスト（TTS音声合成→文字起こし→編集の全経路）
        // 実行: swift run VoicePasteE2E（APIキーはconfig.json or GROQ_API_KEY）
        .executableTarget(
            name: "VoicePasteE2E",
            dependencies: ["VoicePasteCore"]
        ),
    ]
)
