import Foundation
import Sparkle
import Testing
@testable import SkillBoxApp

@MainActor
@Suite("Application update interaction")
struct ApplicationUpdaterTests {
    @Test("A ready update waits for user choice and cannot interrupt work or install twice")
    func readyUpdateIsSingleUseAndWaitsForWork() {
        let driver = ApplicationUpdater()
        var busy = true
        var installCount = 0
        driver.canRestart = { !busy }
        driver.showReady(toInstallAndRelaunch: { choice in if choice == .install { installCount += 1 } })
        #expect(driver.phase == .ready)
        driver.performPrimaryAction()
        #expect(installCount == 0)
        busy = false
        #expect(driver.actionEnabled)
        driver.performPrimaryAction()
        driver.performPrimaryAction()
        #expect(installCount == 1)
    }

    @Test("Download cancellation and progress use the active Sparkle session")
    func cancelDownloadOnce() {
        let driver = ApplicationUpdater()
        var cancels = 0
        driver.showDownloadInitiated { cancels += 1 }
        driver.showDownloadDidReceiveExpectedContentLength(100)
        driver.showDownloadDidReceiveData(ofLength: 25)
        #expect(driver.progress == 0.25)
        driver.showDownloadDidReceiveData(ofLength: 200)
        #expect(driver.progress == 1)
        driver.cancel(); driver.cancel()
        #expect(cancels == 1)
        #expect(driver.phase == .idle)
        #expect(!driver.canCancel)
    }

    @Test("Extraction stops offering download cancellation and waits before restart")
    func extractionWaitsForConsent() {
        let driver = ApplicationUpdater()
        driver.showDownloadInitiated {}
        driver.showDownloadDidStartExtractingUpdate()
        #expect(!driver.canCancel)
        #expect(!driver.actionEnabled)
        driver.showExtractionReceivedProgress(0.75)
        #expect(driver.progress == 0.75)
        driver.showReady(toInstallAndRelaunch: { _ in Issue.record("No implicit installation") })
        #expect(driver.phase == .ready)
    }

    @Test("A network or signature error cannot become a latest-version success")
    func errorsRemainErrorsAfterDismissal() {
        let driver = ApplicationUpdater()
        driver.showUpdaterError(NSError(domain: SUSparkleErrorDomain, code: 3001)) {}
        #expect(driver.detail.contains("校验未通过"))
        driver.dismissUpdateInstallation()
        #expect(driver.phase == .failed)
        #expect(!driver.actionEnabled)
        driver.showUpdaterError(URLError(.notConnectedToInternet)) {}
        #expect(driver.detail.contains("网络"))
        #expect(driver.phase == .failed)
    }

    @Test("Newer local builds and incompatible systems get accurate no-update reasons")
    func noUpdateReasons() {
        let driver = ApplicationUpdater()
        driver.showUpdateNotFoundWithError(NSError(domain: SUSparkleErrorDomain, code: 1001,
            userInfo: [SPUNoUpdateFoundReasonKey: NSNumber(value: 2)])) {}
        #expect(driver.detail.contains("无需降级"))
        driver.showUpdateNotFoundWithError(NSError(domain: SUSparkleErrorDomain, code: 1001,
            userInfo: [SPUNoUpdateFoundReasonKey: NSNumber(value: 3)])) {}
        #expect(driver.detail.contains("暂不支持"))
    }

    @Test("An unpackaged application does not claim to have checked for updates")
    func missingConfigurationIsNotLatest() {
        let driver = ApplicationUpdater()
        driver.start(bundle: .main)
        #expect(driver.phase == .failed)
        #expect(!driver.isConfigured)
        #expect(!driver.canCheck)
    }

    @Test("App termination is deferred if a file operation is still in progress")
    func terminationGate() {
        let delegate = SkillBoxApplicationDelegate()
        delegate.canTerminate = { false }
        #expect(delegate.applicationShouldTerminate(.shared) == .terminateCancel)
        delegate.canTerminate = { true }
        #expect(delegate.applicationShouldTerminate(.shared) == .terminateNow)
    }
}
