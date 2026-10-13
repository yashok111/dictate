import Foundation
let tests = TranscriptTests()
let storageTests = ReviewStorageTests()
let cases: [(String, () throws -> Void)] = [
    ("meeting context metadata", MeetingContextTests().testContextSurvivesMetadataRoundTripAndLegacyRecordsLoad),
    ("meeting context validation", MeetingContextTests().testValidation),
    ("model catalog", ModelCatalogTests().testCatalog),
    ("invalid model catalog", ModelCatalogTests().testRejectsInvalidCatalog),
    ("corrupt recording isolation", storageTests.testCorruptRecordDoesNotHideHealthyLibrary),
    ("unreadable library root", storageTests.testUnreadableLibraryRootStillFails),
    ("invalid recording isolation", storageTests.testInvalidRecordIdentityAndTranscriptAreIsolated),
    ("search highlight ranges", tests.testSearchHighlightsAllLiteralUnicodeMatches),
    ("legacy noise flag preserves transcript", tests.testLegacyNoiseFlagPreservesTranscript),
    ("experimental model selection", tests.testExperimentalModelRequiresExplicitSelectionAndLegacyProfilesStillWork),
    ("native memory policy", tests.testMemoryPolicyCallsNativeSelector),
    ("bundled memory admission", tests.testBundledProfilesFitMeasuredBudgetsAndKeepGuards),
    ("export", tests.testExportRetainsSpeakerEditsAndHourTimestamps),
    ("validation", tests.testInvalidIntervalsAndUnknownSchemaAreRejected),
    ("recovery", tests.testPersistenceKeepsEditsAndMarksRunningJobsInterruptedOnRelaunch),
    ("path traversal", tests.testUnsafeSourceNameCannotEscapeRecordingDirectory),
    ("cancel race", tests.testAttemptGateRejectsLateCompletionAfterCancelOrRestart)
]
var failures = 0
for (name, run) in cases {
    do { try run(); print("PASS: \(name)") }
    catch { failures += 1; print("FAIL: \(name): \(error)") }
}
Task {
    let lifecycleTests = ReviewLifecycleTests()
    let reviewCases: [(String, @MainActor () async throws -> Void)] = [
        ("bulk speaker edit undo and persistence", SpeakerEditTests().testBulkMergeUndoAndSaveFailure),
        ("sticky stage cancellation", PipelineLifecycleTests().testCancellationBetweenProcessesIsSticky),
        ("alignment stage cancellation", PipelineLifecycleTests().testAlignmentCancellationStopsRemainingStages),
        ("complete bundle resume", ModelBundleTests().testCompleteStagingResumesPublication),
        ("model bundle", ModelBundleTests().testBundlePublicationAndCorruption),
        ("meeting context import and repeat", MeetingContextTests().testImportWaitsForConfirmationAndRepeatPreservesOriginal),
        ("meeting context worker file", MeetingContextTests().testWorkerReceivesPrivateContextFile),
        ("model first run and sizes", ModelsControllerTests().testFirstRunDoesNotDownloadAndShowsRequiredBytes),
        ("managed model queue", ModelQueueTests().testMissingModelsWaitAndReadinessStartsOnce),
        ("changing model wakes queue", ModelQueueTests().testChangingToInstalledProfileWakesQueue),
        ("double pause serialization", ModelDownloadTests().testRepeatedPauseHasOneCancellation),
        ("orphan model staging cleanup", ModelStoreTests().testStartupRemovesOnlyOrphanStaging),
        ("managed readiness after shutdown", ModelQueueTests().testReadinessAfterShutdownDoesNotStartWorker),
        ("managed readiness save failure", ModelQueueTests().testReadinessDoesNotBypassFailedSave),
        ("download space preflight", ModelDownloadTests().testInsufficientSpaceDoesNotStartTransfer),
        ("download shared reuse and invalid resume", ModelDownloadTests().testSharedReuseAndInvalidResumeRecovery),
        ("download resume source binding", ModelDownloadTests().testResumeBoundToSource),
        ("real HTTP model downloads", ModelDownloadTests().testRealHTTPTransport),
        ("download repeated clicks and late completion", ModelDownloadTests().testRepeatedInstallAndStaleCompletion),
        ("model publication and leases", ModelStoreTests().testVerifiedPublicationAndLeases),
        ("model corruption and lock", ModelStoreTests().testCorruptFilesAndStoreLock),
        ("model receipt recovery", ModelStoreTests().testReconcileAfterLostReceiptAndChangedFile),
        ("model archive and disk checks", ModelStoreTests().testNoSpaceAndArchiveMembers),
        ("import symlink retains media", storageTests.testImportedSymlinkRetainsMediaAfterOriginalRemoved),
        ("failed import cleanup", storageTests.testFailedImportLeavesNoHiddenRecordDirectory),
        ("failed admission persistence", lifecycleTests.testFailedAdmissionSaveDoesNotStartWorker),
        ("failed completion persistence", lifecycleTests.testCompletionSaveFailureEndsProcessingWithoutRetry),
        ("shutdown stops queue", lifecycleTests.testShutdownDoesNotStartQueuedWork),
        ("termination without window", lifecycleTests.testTerminationNotificationStopsWorkerWithoutAWindow)
    ]
    for (name, run) in reviewCases {
        do { try await run(); print("PASS: \(name)") }
        catch { failures += 1; print("FAIL: \(name): \(error)") }
    }
    do { try await tests.testModelSelectionSurvivesRelaunch(); print("PASS: model selection persistence") }
    catch { failures += 1; print("FAIL: model selection persistence: \(error)") }
    do { try await tests.testLegacyNoiseFlagDoesNotBlockQueue(); print("PASS: legacy noise flag does not block queue") }
    catch { failures += 1; print("FAIL: legacy noise flag queue: \(error)") }
    do { try await tests.testDeleteRemovesOnlySelectedRecordingAndUpdatesSelection(); print("PASS: delete isolation and selection") }
    catch { failures += 1; print("FAIL: delete isolation and selection: \(error)") }
    do { try await tests.testDeleteFailureKeepsRecordingAndSelection(); print("PASS: delete failure preserves record") }
    catch { failures += 1; print("FAIL: delete failure preserves record: \(error)") }
    do { try await tests.testPreviewIsReadOnlyAttemptScopedAndClearedAfterCancelOrCompletion(deleteWhileRunning: true); print("PASS: delete active worker") }
    catch { failures += 1; print("FAIL: delete active worker: \(error)") }
    do { try await tests.testRepeatCreatesANewRecordingWithoutOverwritingEdits(); print("PASS: repeat preserves edits") }
    catch { failures += 1; print("FAIL: repeat preserves edits: \(error)") }
    do { try await tests.testPreviewIsReadOnlyAttemptScopedAndClearedAfterCancelOrCompletion(); print("PASS: preview lifecycle") }
    catch { failures += 1; print("FAIL: preview lifecycle: \(error)") }
    do { try await tests.testQueuedJobStartsOnRelaunch(); print("PASS: queued relaunch") }
    catch { failures += 1; print("FAIL: queued relaunch: \(error)") }
    do { try await tests.testImportAcceptsFilesWhileAnEarlierCopyIsInFlight(); print("PASS: concurrent imports") }
    catch { failures += 1; print("FAIL: concurrent imports: \(error)") }
    do {
        try await tests.testProcessCancellationIsBoundedAndPrelaunchCancelIsHonored()
        print("PASS: process cancellation")
    } catch { failures += 1; print("FAIL: process cancellation: \(error)") }
    exit(failures == 0 ? 0 : 1)
}
dispatchMain()
