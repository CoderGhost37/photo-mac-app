// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "PhotoIndex",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "PhotoIndex", targets: ["PhotoIndex"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
        .package(url: "https://github.com/the-swift-collective/libwebp.git", from: "1.4.0")
    ],
    targets: [
        .target(
            name: "PhotoIndex",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "WebP", package: "libwebp")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "PhotoIndexTests",
            dependencies: ["PhotoIndex"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
