// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FolioCore",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "FolioCore", targets: ["FolioCore"]),
        .executable(name: "folio-storage-probe", targets: ["FolioStorageProbe"]),
        .executable(name: "folio-reading-probe", targets: ["FolioReadingProbe"]),
        .executable(name: "folio-planning-probe", targets: ["FolioPlanningProbe"]),
        .executable(name: "folio-capture-probe", targets: ["FolioCaptureProbe"]),
        .executable(name: "folio-speech-probe", targets: ["FolioSpeechProbe"])
    ],
    targets: [
        .target(name: "FolioFileIO", publicHeadersPath: "include", linkerSettings: [
            .linkedLibrary("crypto", .when(platforms: [.linux]))
        ]),
        .systemLibrary(name: "CSQLite", providers: [.apt(["libsqlite3-dev"])]),
        .target(name: "CArgon2", sources: ["src/argon2.c", "src/core.c", "src/ref.c", "src/encoding.c", "src/blake2/blake2b.c"], publicHeadersPath: "include", cSettings: [.define("ARGON2_NO_THREADS"), .headerSearchPath("src")]),
        .target(name: "FolioRDMPrimitives", dependencies: ["CArgon2"], publicHeadersPath: "include", cSettings: [.headerSearchPath("vendor/libarchive")], linkerSettings: [
            .linkedLibrary("archive"),
            .linkedLibrary("z", .when(platforms: [.linux])),
            .linkedLibrary("lzma", .when(platforms: [.linux])),
            .linkedLibrary("crypto", .when(platforms: [.linux])),
            .linkedFramework("Security", .when(platforms: [.macOS]))
        ]),
        .target(name: "FolioCore", dependencies: ["FolioFileIO", "CSQLite", "FolioRDMPrimitives"]),
        .executableTarget(name: "FolioStorageProbe", dependencies: ["FolioCore"]),
        .executableTarget(name: "FolioReadingProbe", dependencies: ["FolioCore"]),
        .executableTarget(name: "FolioPlanningProbe", dependencies: ["FolioCore"]),
        .executableTarget(name: "FolioCaptureProbe", dependencies: ["FolioCore"]),
        .executableTarget(name: "FolioSpeechProbe", dependencies: ["FolioCore"]),
        .executableTarget(name: "FolioBenchmarkProbe", dependencies: ["FolioCore"]),
        .testTarget(name: "FolioCoreTests", dependencies: ["FolioCore"])
    ]
)
