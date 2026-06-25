// swift-tools-version: 6.2
import PackageDescription

/// A generic, domain-free transport for paginated, bearer-authenticated REST APIs.
/// The target uses the Swift 6 language mode and MainActor default actor isolation,
/// against which the source's `nonisolated` annotations are written so the pagination
/// pipeline can run off the main actor.
let package = Package(
    name: "PaginatedRESTClient",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PaginatedRESTClient", targets: ["PaginatedRESTClient"])
    ],
    targets: [
        .target(
            name: "PaginatedRESTClient",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(MainActor.self),
                // SWIFT_APPROACHABLE_CONCURRENCY: the file's `nonisolated` async methods
                // run on the caller's actor (SE-0461) rather than hopping to the main actor.
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances")
            ]
        ),
        .testTarget(
            name: "PaginatedRESTClientTests",
            dependencies: ["PaginatedRESTClient"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .defaultIsolation(MainActor.self),
                // SWIFT_APPROACHABLE_CONCURRENCY: the file's `nonisolated` async methods
                // run on the caller's actor (SE-0461) rather than hopping to the main actor.
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances")
            ]
        )
    ]
)
