#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

/// The Steam connection steps as a modal sheet.
///
/// Onboarding is the only caller left: there, connecting Steam is one step the
/// user is in the middle of, so it gets its own title bar and Done button.
/// Settings shows the same `WorkshopConnectionSetup` sections inline instead —
/// a settings page is a place you navigate to, not a task you finish and
/// dismiss.
struct WorkshopDoctorView: View {
    @Environment(SteamCMDDoctorService.self) private var service
    @Environment(\.dismiss) private var dismiss
    @State private var showingToast = false

    var body: some View {
        VStack(spacing: 0) {
            navigationBar
            Divider()
            content
            SheetFooterBar(
                primaryTitle: "Done",
                primaryAction: { dismiss() },
                primaryHelp: "Close the Steam connection sheet"
            )
        }
        .frame(
            minWidth: SteamSheetWidth.dense,
            idealWidth: SteamSheetWidth.dense,
            minHeight: 520,
            idealHeight: 580
        )
        .overlay(alignment: .bottom) {
            ExportToast(isPresented: $showingToast)
                .padding(.bottom, DesignTokens.Spacing.xl)
                .allowsHitTesting(false)
        }
    }

    /// The grouped Form is what every other settings surface in the app uses;
    /// this was the one hand-rolled VStack, which is why it never quite looked
    /// like the rest of the app.
    private var content: some View {
        Form {
            Section {
                statusStrip
            }

            WorkshopConnectionSetup(showingExportToast: $showingToast) {
                Text("Setup", bundle: .main)
            }

            Section {
                WorkshopPrivacyLink()
            }
        }
        .settingsFormChrome()
    }

    private var navigationBar: some View {
        HStack {
            Text("Steam connection")
                .font(DesignTokens.Typography.sectionTitle)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DesignTokens.Settings.formHorizontalMargin)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .background(.bar)
    }

    /// One sentence, not a "2 of 3" tally: the rows below already show which
    /// step is outstanding, and a fraction only asks the user to do the diff
    /// themselves. HIG has no counter idiom for a three-item checklist.
    private var statusStrip: some View {
        SteamSheetHeader(
            icon: connectionHeaderIcon,
            title: connectionHeaderTitle,
            iconTint: connectionHeaderTint,
            subtitle: connectionHeaderSubtitle
        )
    }

    // MARK: - Connection status

    private var connectionHeaderTitle: LocalizedStringKey {
        service.isLibraryReady ? "Official Steam library connected" : "Connect your Steam library"
    }

    /// The sentence that replaced the "N of 3" tally — it names the next
    /// action rather than a fraction the user has to interpret.
    private var connectionHeaderSubtitle: LocalizedStringKey? {
        if !service.isLibraryReady { return "Choose Steam's folder to get started." }
        if !service.isBinaryReady { return "Set up SteamCMD to download from the Workshop." }
        if service.accountStepState != .ready { return "Sign in so downloads run as your account." }
        return nil
    }

    private var connectionHeaderIcon: String {
        service.isLibraryReady ? "externaldrive.badge.checkmark" : "externaldrive.badge.exclamationmark"
    }

    private var connectionHeaderTint: Color {
        service.isLibraryReady ? DesignTokens.Colors.Status.active : DesignTokens.Colors.Status.warning
    }
}
#endif
