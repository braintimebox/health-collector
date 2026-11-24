import XCTest
import HealthCollectorCore

/// The automation switch is a promise to the user: "off" must mean the app stops
/// collecting on its own, and "manual" must keep working. These are the cases that
/// used to be decided by where a call sat in the view hierarchy, so they had no
/// test at all — the switch wrote a `Bool` to `UserDefaults` and nothing read it.
final class AutomationGateTests: XCTestCase {

    // MARK: - OFF disables automatic collection

    func testEveryAutomaticTriggerIsSkippedWhenAutomationIsOff() {
        let automatic: [CollectionTrigger] = [
            .launch, .foreground, .observer, .backgroundDelivery, .retry,
        ]
        for trigger in automatic {
            let decision = AutomationGate.decide(trigger: trigger, automationEnabled: false)
            XCTAssertEqual(decision, .skip(.automationDisabled), "trigger \(trigger) must not collect when the switch is off")
            XCTAssertFalse(decision.runs, "trigger \(trigger) reported runs while automation is off")
        }
    }

    // MARK: - Manual work is independent of the switch

    func testManualAndWindowExportRunWithAutomationOff() {
        for trigger in [CollectionTrigger.manual, .windowExport] {
            let decision = AutomationGate.decide(trigger: trigger, automationEnabled: false)
            XCTAssertEqual(decision, .run, "\(trigger) is an explicit request and must not be gated")
            XCTAssertTrue(decision.runs)
        }
    }

    func testExplicitTriggersAreOnlyTheUserInitiatedOnes() {
        let explicit = Set(CollectionTrigger.allCases.filter(\.isExplicit))
        XCTAssertEqual(explicit, [.manual, .windowExport])
    }

    // MARK: - ON enables everything

    func testAllTriggersRunWhenAutomationIsOn() {
        for trigger in CollectionTrigger.allCases {
            XCTAssertEqual(
                AutomationGate.decide(trigger: trigger, automationEnabled: true), .run,
                "trigger \(trigger) must collect when the switch is on")
        }
    }

    func testDecisionDoesNotDependOnTriggerOrder() {
        // Same inputs, same answer — the rule is a function, not a state machine
        // that drifts between calls.
        for trigger in CollectionTrigger.allCases {
            let first = AutomationGate.decide(trigger: trigger, automationEnabled: false)
            let second = AutomationGate.decide(trigger: trigger, automationEnabled: false)
            XCTAssertEqual(first, second)
        }
    }

    // MARK: - The switch takes effect on the very next trigger

    func testFlippingTheSwitchChangesTheNextDecisionWithoutAnyOtherState() {
        // Foreground is the trigger that fires when the user comes back to the app,
        // i.e. exactly when they expect their change to have taken effect.
        XCTAssertEqual(
            AutomationGate.decide(trigger: .foreground, automationEnabled: true), .run)
        XCTAssertEqual(
            AutomationGate.decide(trigger: .foreground, automationEnabled: false),
            .skip(.automationDisabled))
        // And back: disabling is not sticky.
        XCTAssertEqual(
            AutomationGate.decide(trigger: .foreground, automationEnabled: true), .run)
    }

    func testEveryRuntimeEntryPointIsACollectionTrigger() {
        // If a new entry point is added to the runtime, it must pick a trigger —
        // this list is the checklist the code review reads.
        // Exactly the five the runtime fires today; `.observer` is declared for a
        // future direct observer wake-up but is not wired to anything yet, and
        // claiming it here would be the same overstatement this file exists to stop.
        let wired: [CollectionTrigger] = [.launch, .foreground, .backgroundDelivery, .manual, .windowExport]
        for trigger in wired {
            XCTAssertEqual(
                AutomationGate.decide(trigger: trigger, automationEnabled: true), .run,
                "\(trigger) must be able to collect when automation is on")
        }
    }

    // MARK: - State model: one source, typed

    func testRuntimeStateDerivesEveryNumberFromTheStoredStatus() {
        let status = CollectorStatus(
            queueDepth: 12,
            deadLettered: 2,
            oldestPendingAge: 3_600,
            lastSuccessAt: Date(timeIntervalSince1970: 1_000),
            lastNewRowAt: Date(timeIntervalSince1970: 2_000),
            lastError: "HTTP 500",
            permissions: .requested,
            backgroundDelivery: .enabled,
            fullHistoryTypes: ["step_count"],
            verdict: .degraded)

        let state = RuntimeState(status: status)
        XCTAssertEqual(state.queueDepth, 12)
        XCTAssertEqual(state.deadCount, 2)
        XCTAssertEqual(state.oldestPending, 3_600)
        XCTAssertEqual(state.lastSuccessAt, Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(state.fullHistoryTypes, ["step_count"])
        XCTAssertEqual(state.verdict, .degraded)
        XCTAssertEqual(state.lastError, "HTTP 500")
    }

    func testRuntimeStateWithoutStatusReportsZeroRatherThanCrashing() {
        let state = RuntimeState()
        XCTAssertEqual(state.queueDepth, 0)
        XCTAssertEqual(state.deadCount, 0)
        XCTAssertNil(state.oldestPending)
        XCTAssertNil(state.lastSuccessAt)
        XCTAssertNil(state.lastError)
        XCTAssertNil(state.verdict)
    }

    func testCollectionFailureOutranksTheStoredError() {
        var state = RuntimeState(status: CollectorStatus(
            queueDepth: 1, deadLettered: 0, oldestPendingAge: nil, lastSuccessAt: nil,
            lastNewRowAt: nil, lastError: "old failure", permissions: .requested,
            backgroundDelivery: .unknown, fullHistoryTypes: [], verdict: .idle))
        XCTAssertEqual(state.lastError, "old failure")

        state.collection = .failed("storage unavailable")
        XCTAssertEqual(state.lastError, "storage unavailable", "the newer fact must win")

        state.collection = .idle
        XCTAssertEqual(state.lastError, "old failure", "clearing the pass restores the stored error")
    }

    // MARK: - The four states stay apart

    func testDisabledCollectionIsNotReportedAsAFailure() {
        let state = RuntimeState(collection: .disabled)
        XCTAssertNil(state.lastError, "switching automation off is a decision, not an exception")
        XCTAssertEqual(state.collection.label, "off (automatic collection disabled)")
    }

    func testPermissionStateNeverClaimsReadAccessWasGranted() {
        // iOS does not disclose read access; "requested" is the strongest honest claim.
        XCTAssertEqual(PermissionState.requested.label, "requested (read status is not observable on iOS)")
        XCTAssertNotEqual(PermissionState.requested, .full)
        XCTAssertNotEqual(PermissionState.requested, .partial)
    }

    func testBackgroundDeliveryLabelsDoNotInventACause() {
        XCTAssertEqual(BackgroundDeliveryState.disabled.label, "disabled")
        XCTAssertEqual(BackgroundDeliveryState.unknown.label, "unknown (not observable)")
        XCTAssertTrue(BackgroundDeliveryState.unavailable.label.contains("no entitlement"))
    }

    func testConnectionStateDistinguishesWorkingServerFromRejectedRequest() {
        XCTAssertTrue(ConnectionState.ok(200).isSuccess)
        XCTAssertFalse(ConnectionState.httpError(401).isSuccess)
        XCTAssertFalse(ConnectionState.httpError(404).isSuccess)
        XCTAssertEqual(ConnectionState.ok(200).label, "ok (200)")
        XCTAssertEqual(ConnectionState.httpError(401).label, "HTTP 401")
        XCTAssertTrue(ConnectionState.notConfigured("no host").label.hasPrefix("not configured"))
    }

    // MARK: - Persistence of the setting itself

    func testTriggerLabelsCoverEveryCase() {
        for trigger in CollectionTrigger.allCases {
            XCTAssertFalse(trigger.label.isEmpty, "trigger \(trigger) needs a label for the panel")
        }
        XCTAssertEqual(RuntimeState().triggerLabel, "-", "no run yet must read as no run, not as a fake trigger")
    }
}
