// Copyright (c) 2026 OwnGoal Studio. MIT; see LICENSE beside this file.
// Table/action-bar layout copied from Irisin's WelcomeRepositoriesController.
import ApelinCore
import ApelinProtocol
import UIKit

/// The recommended toolchain and SDK for this device. The page's button
/// installs them while anything is missing and moves on once both are in;
/// Not Now skips the step, and Retry follows a failure. Where every release
/// is refused for one reason, the page says that reason and lists nothing.
final class WelcomeEnvironmentPage: WelcomeListPage {
    private enum Section: Hashable { case introduction, recommended }
    private enum Row: Hashable { case introduction, toolchain, sdk }
    private enum Primary { case install, next, retry }
    private lazy var dataSource = TableDataSource<Section, Row, Row>(
        tableView: tableView,
        identifier: { $0 },
    ) { [weak self] _, _, row in
        switch row {
        case .introduction:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            var content = UIListContentConfiguration.cell()
            content.text = switch self?.introduction {
            // the service's own words, read in the user's language when
            // the catalogue has them (roothide Bootstrap's)
            case let .refusal(reason)?: String(localized: String.LocalizationValue(reason))
            default: String(localized: "A compatible toolchain and iOS SDK, selected for this device. You can also install them later in Settings.")
            }
            content.textProperties.font = .preferredFont(forTextStyle: .body)
            content.textProperties.numberOfLines = 0
            cell.contentConfiguration = content
            cell.selectionStyle = .none
            return cell
        case .toolchain: return self?.toolchainRow
        case .sdk: return self?.sdkRow
        }
    }

    private var recommendation: WelcomeEnvironmentRecommendation?
    private var introduction = WelcomeEnvironmentIntroduction.recommendation
    private var operation: Task<Void, Never>?
    @objc private dynamic var activeInstallation = false
    @objc private dynamic var installing = false
    @objc private dynamic var resolving = true
    /// Loading or installing failed; the page's button tries again.
    @objc private dynamic var failed = false
    @objc private dynamic var statusText: String?
    private let toolchainRow = WelcomeToolRow()
    private let sdkRow = WelcomeToolRow()
    private let recommendedHeader = WelcomeSectionHeader(reuseIdentifier: "recommended")

    deinit { operation?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Build Tools")
        next { [weak self] in self?.performPrimary() }
        updateRows()
        dataSource.update(sections)
        load()
    }

    /// The pair's rows, unless the introduction says why there is none.
    private var sections: [(Section, [Row])] {
        switch introduction {
        case .recommendation: [(.introduction, [.introduction]), (.recommended, [.toolchain, .sdk])]
        case .refusal: [(.introduction, [.introduction])]
        }
    }

    private func show(_ introduction: WelcomeEnvironmentIntroduction) {
        guard introduction != self.introduction else { return }
        self.introduction = introduction
        dataSource.update(sections, changedItems: [.introduction])
    }

    @objc(apelin_load) private dynamic func load() {
        operation?.cancel()
        dataSource.beginLoad()
        resolving = true
        failed = false
        activeInstallation = false
        statusText = nil
        updateRows()
        operation = Task { [weak self] in
            do {
                async let catalog = ApelinService.app.toolchainCatalog()
                async let toolchains = ApelinService.app.toolchainStatus()
                async let sdks = ApelinService.app.sdkList(includeSources: true, readSources: true)
                let values = try await (catalog, toolchains, sdks)
                guard !Task.isCancelled, let self else { return }
                resolving = false
                recommendation = WelcomeEnvironmentRecommendation.resolve(
                    catalog: values.0.products,
                    status: values.1,
                    sdks: values.2,
                )
                activeInstallation = !values.1.activeTasks.isEmpty || !values.2.activeTasks.isEmpty
                show(WelcomeEnvironmentIntroduction(catalog: values.0.products))
                if recommendation == nil {
                    statusText = String(localized: "No compatible versions are available. You can set up build tools later in Settings.")
                } else if activeInstallation {
                    statusText = String(localized: "An installation is in progress. Check Settings for details.")
                }
                updateRows()
            } catch {
                guard !Task.isCancelled, let self else { return }
                resolving = false
                failed = true
                recommendation = nil
                // the rows say what failed, and Retry is for them
                show(.recommendation)
                statusText = String(localized: "Unable to load recommendations. Tap “Retry” or continue to set up later.")
                updateRows()
            }
        }
    }

    @objc dynamic func tableView(_: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        dataSource.itemIdentifier(for: indexPath) == .introduction
            ? UITableView.automaticDimension : UIFontMetrics(forTextStyle: .body).scaledValue(for: 65)
    }

    @objc dynamic func tableView(_: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        dataSource.sectionIdentifier(for: section) == .introduction
            ? nil
            : recommendedHeader
    }

    @objc dynamic func tableView(_: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard dataSource.itemIdentifier(for: indexPath) != .introduction,
              let statusText, !resolving, !installing else { return }
        presentNotice(title: "Build Tools", message: statusText)
    }

    @objc private dynamic func updateRows() {
        let toolTitle = recommendation.map { String(localized: "Command Line Tools \($0.toolchain.version)") }
            ?? String(localized: "Command Line Tools")
        let sdkTitle = recommendation.map { String(localized: "iOS SDK \($0.sdk.version)") }
            ?? String(localized: "iOS SDK")
        let loadingDetail = String(localized: "Finding a compatible version…")
        let languages = recommendation?.includesSwift == true
            ? String(localized: "Swift, Objective-C, C and C++")
            : String(localized: "Objective-C, C and C++")
        let toolDetail = resolving ? loadingDetail : statusText ?? languages
        let sdkDetail: String = if resolving {
            loadingDetail
        } else if recommendation == nil {
            statusText ?? loadingDetail
        } else {
            recommendation?.sdk.installed == true
                ? String(localized: "Installed")
                : String(localized: "Ready to download")
        }
        toolchainRow.configure(
            title: toolTitle,
            detail: toolDetail,
            loading: resolving,
            installed: recommendation?.installedToolchain != nil,
        )
        sdkRow.configure(
            title: sdkTitle,
            detail: sdkDetail,
            loading: resolving,
            installed: recommendation?.sdk.installed == true,
        )
        recommendedHeader.configure(title: String(localized: "Recommended"), showsButton: false)
        let primary = primary
        actionBar.title = switch primary {
        case .install: String(localized: "Install")
        case .next: String(localized: "Next")
        case .retry: String(localized: "Retry")
        }
        actionBar.isEnabled = !resolving && !installing
        actionBar.isSecondaryHidden = primary == .next
    }

    @objc override dynamic var secondaryTitle: String? {
        String(localized: "Not Now")
    }

    @objc override dynamic func secondaryAction() {
        flow.showProviders()
    }

    /// Install while something recommended is missing, Retry after a
    /// failure, Next once there is nothing left to install here.
    private var primary: Primary {
        if failed {
            return .retry
        }
        if resolving || installing {
            return .install
        }
        guard let recommendation, !activeInstallation, !recommendation.isInstalled else { return .next }
        return .install
    }

    @objc private dynamic func performPrimary() {
        switch primary {
        case .install: install()
        case .retry: load()
        case .next: flow.showProviders()
        }
    }

    /// The installation is the host's task on Settings' own page, opened
    /// as a sheet: Continue in Background leaves it running, and its end
    /// reads the recommendation again. A missing toolchain's setup brings
    /// the SDK it compiles against too; an SDK alone is imported.
    @objc private dynamic func install() {
        guard let recommendation, !activeInstallation, !installing else { return }
        installing = true
        updateRows()
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let page: EnvironmentTaskController
                if recommendation.installedToolchain == nil {
                    let components: [ToolchainComponentKind] = recommendation.includesSwift ? [.c, .swift] : [.c]
                    let handle = try await ApelinService.app.toolchainSetup(.init(
                        source: .appleCatalog(productID: recommendation.toolchain.productID),
                        components: components,
                    ))
                    page = EnvironmentTaskController(
                        handle: handle,
                        work: .toolchainSetup,
                        title: String(localized: "Setting Up Toolchain"),
                        doneTitle: String(localized: "Toolchain Ready"),
                    )
                } else if let source = recommendation.sdk.source {
                    let handle = try await ApelinService.app.sdkImport(source)
                    page = EnvironmentTaskController(
                        handle: handle,
                        work: .sdkImport,
                        title: String(localized: "Importing SDK"),
                        doneTitle: String(localized: "SDK Imported"),
                    )
                } else {
                    installing = false
                    load()
                    return
                }
                installing = false
                page.onFinish = { [weak self] in
                    NotificationCenter.default.post(name: TransferOpener.environmentChanged, object: nil)
                    self?.load()
                }
                presentAsFormSheet(SheetNavigationController(rootViewController: page))
                load()
            } catch {
                guard !Task.isCancelled else { return }
                installing = false
                failed = true
                self.recommendation = nil
                statusText = error.readableMessage
                updateRows()
            }
        }
    }
}
