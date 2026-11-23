import SwiftUI

// Entry point only. The HealthKit work lives in HealthKitSource.swift, the
// runtime and diagnostics in Runtime.swift.
//
// The profile question is answered before install by scripts/check-profile.py:
// `enableBackgroundDelivery` returns `errorAuthorizationDenied` both for a missing
// entitlement and for a denied user, so a runtime probe cannot tell them apart.

@main
struct HealthCollectorApp: App {
    @StateObject private var runtime = CollectorRuntime()

    var body: some Scene {
        WindowGroup {
            RuntimeView(runtime: runtime)
                .task { runtime.start() }
        }
    }
}
