// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KakaoSapiens",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "KakaoSapiens", targets: ["KakaoSapiens"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "KakaoSapiens",
            dependencies: [],
            path: "Sources/KakaoSapiens",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
