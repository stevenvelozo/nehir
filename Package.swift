// swift-tools-version: 6.3
// SPDX-FileCopyrightText: 2026 BarutSRB
// SPDX-FileCopyrightText: 2026 Aleksei Gurianov and Nehir contributors
// SPDX-FileComment: Provenance=upstream-derived; Upstream-Project=OmniWM; Upstream-Author=BarutSRB; Nehir-Changes-Since=2026; See=NOTICE.md
//
// SPDX-License-Identifier: GPL-2.0-only

import Foundation
import PackageDescription

let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
    name: "Nehir",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(
            name: "Nehir",
            targets: ["NehirApp"]
        ),
        .executable(
            name: "nehirctl",
            targets: ["NehirCtl"]
        ),
        // NEHIR-SHELL SEAM — shell control-socket client.
        .executable(
            name: "nehirshellctl",
            targets: ["NehirShellCtl"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/mattt/swift-toml.git", from: "2.0.0"),
        // NEHIR-SHELL SEAM — Sparkle auto-updater. A fork feature used only by the
        // NehirShell layer; upstream builds without it stay untouched.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .target(
            name: "NehirIPC",
            path: "Sources/NehirIPC",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .target(
            name: "Nehir",
            dependencies: [
                "NehirIPC",
                .product(name: "TOML", package: "swift-toml")
            ],
            path: "Sources/Nehir",
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .interoperabilityMode(.C),
                .unsafeFlags(["-enable-testing"])
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                .linkedLibrary("z"),
                .linkedLibrary("c++"),
                .unsafeFlags(["-F/System/Library/PrivateFrameworks", "-framework", "SkyLight"])
            ]
        ),
        // NEHIR-SHELL SEAM — C shim for the JavaScriptCore execution-time-limit SPI
        // (used to bound user-authored overlay scripts). Contained here so the SPI
        // lives in one auditable place.
        .target(
            name: "NehirJSCLimit",
            path: "Sources/NehirJSCLimit",
            linkerSettings: [
                .linkedFramework("JavaScriptCore")
            ]
        ),
        // NEHIR-SHELL SEAM — reusable fable/pict-in-Swift bridge (JavaScriptCore host).
        // Standalone: depends on nothing in Nehir, so it can be lifted into any Swift app.
        .target(
            name: "FableCore",
            dependencies: ["NehirJSCLimit"],
            path: "Sources/FableCore",
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ],
            linkerSettings: [
                .linkedFramework("JavaScriptCore")
            ]
        ),
        // NEHIR-SHELL SEAM — out-of-process Node runtime behind the FableRuntime
        // protocol (network/fs/DB work JavaScriptCore cannot do).
        .target(
            name: "NodeSidecar",
            dependencies: ["FableCore"],
            path: "Sources/NodeSidecar",
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        // NEHIR-SHELL SEAM — shared wire types (socket path + protocol) for the
        // shell server and the nehirshellctl client. Lightweight: no WM, no JSC.
        .target(
            name: "NehirShellWire",
            path: "Sources/NehirShellWire",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        // NEHIR-SHELL SEAM — fork extension layer (see Sources/NehirShell).
        .target(
            name: "NehirShell",
            dependencies: [
                "Nehir",
                "NehirIPC",
                "FableCore",
                "NehirShellWire",
                .product(name: "TOML", package: "swift-toml"),
                // NEHIR-SHELL SEAM — Sparkle auto-updater (fork feature).
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/NehirShell",
            resources: [
                // Vendored pict + pict-section-content bundles for the help prose pane.
                .process("Resources")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        // NEHIR-SHELL SEAM — terminal client for the shell control socket.
        .executableTarget(
            name: "NehirShellCtl",
            dependencies: ["NehirShellWire"],
            path: "Sources/NehirShellCtl",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "NehirApp",
            // NEHIR-SHELL SEAM — "NehirShell" pulls the fork extension layer into the app.
            dependencies: ["Nehir", "NehirShell"],
            path: "Sources/NehirApp",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .executableTarget(
            name: "NehirCtl",
            dependencies: ["NehirIPC"],
            path: "Sources/NehirCtl",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "NehirTests",
            dependencies: ["Nehir", "NehirIPC", "NehirCtl"],
            path: "Tests/NehirTests",
            resources: [
                .process("Fixtures")
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        )
    ]
)
