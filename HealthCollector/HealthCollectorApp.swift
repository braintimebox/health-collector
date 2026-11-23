import SwiftUI

// Deliberately no HealthKit call in this build.
//
// The first thing this bundle has to answer is whether the signing profile carries
// `com.apple.developer.healthkit` and `…healthkit.background-delivery`. iOS answers
// that at install time, by rejecting an app whose entitlements the profile does not
// grant. A runtime probe would blur that answer: `enableBackgroundDelivery` returns
// `errorAuthorizationDenied` both when the entitlement is missing and when the user
// declined read access, and HealthKit refuses to tell an app which of the two it hit.
// So the probe comes after the profile question is closed, not before it.

@main
struct HealthCollectorApp: App {
    var body: some Scene {
        WindowGroup {
            SkeletonView()
        }
    }
}

struct SkeletonView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Health Collector")
                .font(.title2.bold())
            Text("Skeleton build: an unsigned bundle that carries the entitlements file it will be signed with.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(buildIdentity)
                .font(.footnote.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var buildIdentity: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let bundleID = info?["CFBundleIdentifier"] as? String ?? "?"
        return "\(bundleID) \(short) (\(build))"
    }
}
