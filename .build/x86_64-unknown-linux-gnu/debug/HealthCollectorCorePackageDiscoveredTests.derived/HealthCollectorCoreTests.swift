import XCTest
@testable import HealthCollectorCoreTests

fileprivate extension DurabilityTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static nonisolated(unsafe) let __allTests__DurabilityTests = [
        ("testAckedRowsAreNotResent", testAckedRowsAreNotResent),
        ("testDuplicateEnqueueIsRefused", testDuplicateEnqueueIsRefused),
        ("testInflightRowsAreRequeuedOnLaunch", testInflightRowsAreRequeuedOnLaunch),
        ("testQueueIsEmptyOnlyWhenItIsEmpty", testQueueIsEmptyOnlyWhenItIsEmpty),
        ("testRowsSurviveProcessDeath", testRowsSurviveProcessDeath)
    ]
}

fileprivate extension ReimportTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static nonisolated(unsafe) let __allTests__ReimportTests = [
        ("testAuthorizationFailurePropagatesAndDoesNotAdvanceCursor", testAuthorizationFailurePropagatesAndDoesNotAdvanceCursor),
        ("testCursorDoesNotAdvanceWhenTheRowCannotBePersisted", testCursorDoesNotAdvanceWhenTheRowCannotBePersisted),
        ("testDeletionIsQueuedIndependentlyOfItsInsert", testDeletionIsQueuedIndependentlyOfItsInsert),
        ("testFullReimportAfterCleanInstallDoesNotResurrectDeletedRecords", testFullReimportAfterCleanInstallDoesNotResurrectDeletedRecords),
        ("testSecondCollectIsIdempotentForAlreadyQueuedRows", testSecondCollectIsIdempotentForAlreadyQueuedRows),
        ("testUnreadableStoreIsNotAnEmptyFetch", testUnreadableStoreIsNotAnEmptyFetch)
    ]
}

fileprivate extension SyncTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static nonisolated(unsafe) let __allTests__SyncTests = [
        ("testBackoffGrowsAndIsCapped", testBackoffGrowsAndIsCapped),
        ("testClientErrorIsDeadLetteredNotRetriedForever", testClientErrorIsDeadLetteredNotRetriedForever),
        ("testFailureClassification", testFailureClassification),
        ("testNetworkDownKeepsRowsQueued", testNetworkDownKeepsRowsQueued),
        ("testPartialAckResendsOnlyUnacked", testPartialAckResendsOnlyUnacked),
        ("testQueueDrainsInOrderWhenNetworkReturns", testQueueDrainsInOrderWhenNetworkReturns),
        ("testRetryAfterIsHonoured", testRetryAfterIsHonoured),
        ("testSilenceIsNotCalledHealthy", testSilenceIsNotCalledHealthy),
        ("testStatusComesFromTheStore", testStatusComesFromTheStore),
        ("testUnreadableAckIsUnconfirmed", testUnreadableAckIsUnconfirmed)
    ]
}

fileprivate extension TransferTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static nonisolated(unsafe) let __allTests__TransferTests = [
        ("testBatchIsOnDiskBeforeTheUploadStarts", testBatchIsOnDiskBeforeTheUploadStarts),
        ("testSpoolIsNotUsedWhenTheTransportSendsFromMemory", testSpoolIsNotUsedWhenTheTransportSendsFromMemory),
        ("testSpooledBatchSurvivesRelaunchAndIsResentFromTheStore", testSpooledBatchSurvivesRelaunchAndIsResentFromTheStore),
        ("testWakeSettlesTheFinishedUploadAndArmsTheNextBatch", testWakeSettlesTheFinishedUploadAndArmsTheNextBatch)
    ]
}

fileprivate extension WireTests {
    @available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
    static nonisolated(unsafe) let __allTests__WireTests = [
        ("testAnchorFileKeepsRawTypeKeys", testAnchorFileKeepsRawTypeKeys),
        ("testDeletesTravelInTheirOwnArray", testDeletesTravelInTheirOwnArray),
        ("testIdentityIsScopedPerUser", testIdentityIsScopedPerUser),
        ("testIdentityIsTenantAndRecordOnly", testIdentityIsTenantAndRecordOnly),
        ("testNilCursorMeansFullHistoryAndIsRecoverable", testNilCursorMeansFullHistoryAndIsRecoverable),
        ("testTimestampKeepsTheOffsetAndTheInstant", testTimestampKeepsTheOffsetAndTheInstant),
        ("testTimestampWithoutFractionalSecondsStillParses", testTimestampWithoutFractionalSecondsStillParses),
        ("testWireContractCarriesSnakeCaseFieldsAndSourceIdentity", testWireContractCarriesSnakeCaseFieldsAndSourceIdentity)
    ]
}
@available(*, deprecated, message: "Not actually deprecated. Marked as deprecated to allow inclusion of deprecated tests (which test deprecated functionality) without warnings")
func __HealthCollectorCoreTests__allTests() -> [XCTestCaseEntry] {
    return [
        testCase(DurabilityTests.__allTests__DurabilityTests),
        testCase(ReimportTests.__allTests__ReimportTests),
        testCase(SyncTests.__allTests__SyncTests),
        testCase(TransferTests.__allTests__TransferTests),
        testCase(WireTests.__allTests__WireTests)
    ]
}