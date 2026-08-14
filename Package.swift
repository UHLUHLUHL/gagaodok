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
                // katex/fonts 같은 하위 디렉터리 구조가 그대로 유지되어야 상대 경로가 맞습니다.
                .copy("Resources")
            ]
        )
    ]
)
