import Foundation
@testable import LiveWallpaper
import Testing

@Suite("Web failure cause")
struct WebFailureCauseTests {
    @Test("A request timeout or a rate limit is worth retrying by hand")
    func transientClientStatusesStayRetryable() {
        #expect(WebFailureCause.httpStatus(408, isLocalProject: false).canRetry)
        #expect(WebFailureCause.httpStatus(429, isLocalProject: false).canRetry)
        #expect(!WebFailureCause.httpStatus(404, isLocalProject: false).canRetry)
    }

    @Test("A remote resource that is unavailable is not a missing local entry page")
    func remoteResourceUnavailableIsNotAMissingEntry() {
        let remote = WebFailureCause.navigation(
            domain: NSURLErrorDomain, code: NSURLErrorResourceUnavailable, description: "gone", isLocalProject: false
        )
        #expect(remote.code != "web.entry_missing")
        #expect(remote.canRetry)
        let local = WebFailureCause.navigation(
            domain: NSURLErrorDomain, code: NSURLErrorResourceUnavailable, description: "gone", isLocalProject: true
        )
        #expect(local.code == "web.entry_missing")
    }

    @Test("A missing entry page is a missing part, not a generic load failure")
    func missingEntryPageIsAMissingPart() {
        let fromURLError = WebFailureCause.navigation(
            domain: NSURLErrorDomain, code: NSURLErrorFileDoesNotExist, description: "no such file"
        )
        let fromHTTP = WebFailureCause.httpStatus(404, isLocalProject: true)

        #expect(fromURLError.code == "web.entry_missing")
        #expect(fromHTTP.code == "web.entry_missing")
        #expect(fromURLError.failureClass == .needsParts)
        #expect(!fromURLError.canRetry)
        // Retrying the same folder cannot conjure the page; re-picking the source can.
        #expect(fromURLError.recovery(workshopID: nil, canChooseSource: true) == [.chooseSource])
    }

    /// The folder scheme hands WebKit plain file errors, never HTTP statuses, so the Cocoa codes
    /// a local project can produce need the same classification as the URL-error ones.
    @Test("Local Cocoa file errors classify like their URL-error twins")
    func localCocoaFileErrorsClassify() {
        let missing = WebFailureCause.navigation(
            domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError, description: "260", isLocalProject: true
        )
        let denied = WebFailureCause.navigation(
            domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError, description: "257", isLocalProject: true
        )
        let directory = WebFailureCause.navigation(
            domain: NSURLErrorDomain, code: NSURLErrorCannotOpenFile, description: "dir", isLocalProject: true
        )
        let remoteMissing = WebFailureCause.navigation(
            domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError, description: "260", isLocalProject: false
        )
        #expect(missing.code == "web.entry_missing")
        #expect(denied.code == "web.resource_denied")
        #expect(directory.code == "web.entry_missing")
        #expect(remoteMissing.code == "web.NSCocoaErrorDomain.260")
    }

    @Test("A refused folder offers re-picking the source rather than a Retry that cannot work")
    func refusedFolderOffersSourceRelink() {
        let cause = WebFailureCause.navigation(
            domain: NSURLErrorDomain, code: NSURLErrorNoPermissionsToReadFile, description: "denied"
        )

        #expect(cause.code == "web.resource_denied")
        #expect(cause.needsSourceRelink)
        #expect(cause.recovery(workshopID: nil, canChooseSource: true) == [.chooseSource])
    }

    @Test("A blocked port is fatal, so no recovery action is offered")
    func blockedPortIsFatal() {
        let cause = WebFailureCause.navigation(domain: "WebKitErrorDomain", code: 103, description: "port")

        #expect(cause.code == "web.blocked_port")
        #expect(cause.failureClass == .fatal)
        #expect(cause.recovery(workshopID: nil, canChooseSource: true).isEmpty)
    }

    @Test("Only a server-side status can retry")
    func onlyServerSideStatusCanRetry() {
        #expect(WebFailureCause.httpStatus(500, isLocalProject: true).code == "web.http_status")
        #expect(WebFailureCause.httpStatus(500, isLocalProject: true).canRetry)
        #expect(!WebFailureCause.httpStatus(403, isLocalProject: true).canRetry)
    }

    /// A remote host's 404 is a server answer, not a broken project folder; reporting it as the
    /// latter tells the user to fix content they do not own.
    @Test("A remote 404 is a server status, not a missing entry page")
    func remote404IsAServerStatus() {
        let remote = WebFailureCause.httpStatus(404, isLocalProject: false)

        #expect(remote.code == "web.http_status")
        #expect(!remote.canRetry)
        #expect(remote.reason != WebFailureCause.httpStatus(404, isLocalProject: true).reason)
    }

    @Test("Offline and unreachable host stay apart")
    func offlineAndUnreachableHostStayApart() {
        let offline = WebFailureCause.navigation(
            domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, description: "offline"
        )
        let unreachable = WebFailureCause.navigation(
            domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost, description: "no host"
        )

        #expect(offline.code == "web.offline")
        #expect(unreachable.code == "web.host_unreachable")
        #expect(offline.reason != unreachable.reason)
    }

    /// `code` is an open namespace, so an unmapped error must still arrive with its domain and
    /// number rather than collapsing into a neighbouring bucket.
    @Test("An unmapped error keeps its own code and the system description")
    func unmappedErrorKeepsItsOwnCode() {
        let url = WebFailureCause.navigation(domain: NSURLErrorDomain, code: -4242, description: "odd")
        let webKit = WebFailureCause.navigation(domain: "WebKitErrorDomain", code: 999, description: "odd")
        let other = WebFailureCause.navigation(domain: "OtherDomain", code: 7, description: "odd")

        #expect(url.code == "web.url_error.-4242")
        #expect(webKit.code == "web.webkit_error.999")
        #expect(other.code == "web.OtherDomain.7")
        #expect(url.failureClass == .blocked)
        #expect(url.reason == "odd")
    }

    @Test("A renderer crash is its own code and stays retryable")
    func rendererCrashIsItsOwnCode() {
        let cause = WebFailureCause.rendererCrashed()

        #expect(cause.code == "web.renderer_crashed")
        #expect(cause.canRetry)
        #expect(cause.recovery(workshopID: nil, canChooseSource: false) == [.retry])
    }
}
