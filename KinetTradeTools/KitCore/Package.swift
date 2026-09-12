// swift-tools-version:5.3
// KitCore — KinetTradeTools 共享计算底座(弯管/分数英寸/单位换算)
import PackageDescription

let package = Package(
    name: "KitCore",
    products: [
        .library(name: "KitCore", targets: ["KitCore"])
    ],
    targets: [
        .target(
            name: "KitCore",
            resources: [.copy("benddata.json")]
        ),
        .testTarget(
            name: "KitCoreTests",
            dependencies: ["KitCore"]
        )
    ]
)
