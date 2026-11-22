import ApelinCore
import ApelinProtocol
import SPIndicator
import Then
import UIKit

/// Settings ▸ Skills ▸ From GitHub…: a link to a public repository, a
/// folder in one or a `SKILL.md`; the skills found there at one commit
/// (`GitHubSkillScanner`), each with its description and how many files it
/// brings, ticked to import; and what cannot be imported, with why. The
/// check leads each row and a tap ticks it, as Wi-Fi's list does; the
/// trailing button previews the `SKILL.md` as plain text. Import asks first
/// before it replaces a skill of the same name, downloads the ticked
/// skills on the progress card into a temporary folder and hands each to
/// `SkillFolder`, as Files does. Nothing in the repository runs.
final class GitHubSkillsController: TableController, UITextFieldDelegate {
    /// Called with the places of the skills imported, once the sheet closes.
    @objc dynamic var onImport: (([String]) -> Void)?

    private enum Section: Hashable {
        case link
        case skills
        case unavailable
    }

    private enum Row: Equatable {
        case field
        case find(enabled: Bool)
        case skill(GitHubSkillCandidate, ticked: Bool)
        case unavailable(GitHubSkillCandidate)

        var id: String {
            switch self {
            case .field: "field"
            case .find: "find"
            case let .skill(candidate, _): "skill:" + candidate.folder
            case let .unavailable(candidate): "unavailable:" + candidate.folder
            }
        }
    }

    private let folder: SkillFolder
    private let scanner: GitHubSkillScanner
    /// The skills listed when the sheet opened: built-in names, and the
    /// folder's skills an import would replace.
    private var listing: AgentSkillListResponse?
    private var scan: GitHubSkillScan?
    @objc private dynamic var tickedFolders: Set<String> = []
    @objc private dynamic var isWorking = false

    private let linkField = UITextField()
    @objc private dynamic lazy var fieldCell = UITableViewCell(style: .default, reuseIdentifier: nil).then { cell in
        cell.selectionStyle = .none
        cell.isAccessibilityElement = false
        linkField.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(linkField)
        NSLayoutConstraint.activate([
            linkField.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            linkField.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            linkField.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 12),
            linkField.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -12),
        ])
    }

    private lazy var dataSource = TableDataSource<Section, String, Row>(
        tableView: tableView,
        identifier: \.id,
    ) { [weak self] table, _, row in
        self?.cell(in: table, for: row)
    }

    @objc private dynamic lazy var importButton = UIBarButtonItem(
        title: String(localized: "Import"),
        primaryAction: UIAction { [weak self] _ in self?.confirmImport() },
    ).then { $0.style = .done }

    @objc private dynamic lazy var selectAllButton = UIBarButtonItem(
        title: String(localized: "Select All"),
        primaryAction: UIAction { [weak self] _ in self?.toggleSelectAll() },
    )

    init(folder: SkillFolder, listing: AgentSkillListResponse?, scanner: GitHubSkillScanner = .live) {
        self.folder = folder
        self.listing = listing
        self.scanner = scanner
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(folder:listing:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Import from GitHub")
        navigationItem.rightBarButtonItem = importButton
        toolbarItems = [selectAllButton, UIBarButtonItem(systemItem: .flexibleSpace)]
        tableView.keyboardDismissMode = .onDrag
        linkField.do {
            $0.delegate = self
            // the start of every link the sheet takes, in no language
            $0.placeholder = "https://github.com/"
            $0.accessibilityLabel = String(localized: "GitHub Link")
            $0.font = .preferredFont(forTextStyle: .body)
            $0.adjustsFontForContentSizeCategory = true
            $0.keyboardType = .URL
            $0.textContentType = .URL
            $0.autocapitalizationType = .none
            $0.autocorrectionType = .no
            $0.spellCheckingType = .no
            $0.clearButtonMode = .whileEditing
            $0.returnKeyType = .search
            $0.addAction(UIAction { [weak self] _ in self?.updateRows() }, for: .editingChanged)
        }
        dataSource.headerTitle = { section in
            switch section {
            case .link: String(localized: "GitHub Link")
            case .skills: String(localized: "Skills")
            case .unavailable: String(localized: "Cannot Be Imported")
            }
        }
        dataSource.footerTitle = { [weak self] section in
            switch section {
            case .link:
                String(localized: """
                A public repository, a folder in one, or a SKILL.md. Apelin lists the skills it finds there. \
                Nothing in the repository runs, and hidden files, links and submodules stay behind.
                """)
            case .skills: self?.skillsFooter
            case .unavailable: nil
            }
        }
        updateRows()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateToolbar(animated: false)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if scan == nil {
            linkField.becomeFirstResponder()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // a pushed preview has no toolbar of its own
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    @objc dynamic func textFieldShouldReturn(_: UITextField) -> Bool {
        findSkills()
        return false
    }

    // MARK: - Rows

    /// Where the skills were read and at which commit, and how many a scan
    /// left unlisted.
    @objc private dynamic var skillsFooter: String? {
        guard let scan else { return nil }
        let place = scan.place
        let location = place.path.isEmpty ? place.fullName : place.fullName + "/" + place.path
        let commit = String(place.commit.prefix(7))
        var footer = place.refIsCommit
            ? String(localized: "From \(location) at commit \(commit).")
            : String(localized: "From \(location) on \(place.ref), at commit \(commit).")
        if scan.omitted > 0 {
            footer += "\n\n" + String(localized: "\(scan.omitted) more skills are not listed. To see them, paste a link to a folder in this repository.")
        }
        return footer
    }

    @objc private dynamic func updateRows() {
        let link = (linkField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var sections: [(Section, [Row])] = [(.link, [.field, .find(enabled: !link.isEmpty && !isWorking)])]
        if let scan {
            let importable = scan.candidates.filter { $0.problem == nil }
            let unavailable = scan.candidates.filter { $0.problem != nil }
            if !importable.isEmpty || scan.omitted > 0 {
                sections.append((.skills, importable.map { .skill($0, ticked: tickedFolders.contains($0.folder)) }))
            }
            if !unavailable.isEmpty {
                sections.append((.unavailable, unavailable.map(Row.unavailable)))
            }
        }
        dataSource.update(sections, reconfigure: true)
        importButton.isEnabled = !tickedFolders.isEmpty && !isWorking
        updateToolbar(animated: true)
    }

    /// Select All while some importable skill is unticked, Deselect All
    /// otherwise; shown only when there are two or more to choose from.
    @objc private dynamic func updateToolbar(animated: Bool) {
        let all = scan.map { GitHubSkillImportPlan.all(of: $0.candidates) } ?? []
        selectAllButton.title = !all.isEmpty && all.isSubset(of: tickedFolders)
            ? String(localized: "Deselect All")
            : String(localized: "Select All")
        selectAllButton.isEnabled = !isWorking
        guard viewIfLoaded?.window != nil || !animated else { return }
        navigationController?.setToolbarHidden(all.count < 2, animated: animated)
    }

    private func cell(in tableView: UITableView, for row: Row) -> UITableViewCell {
        if case .field = row {
            return fieldCell
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: "row") ?? UITableViewCell(style: .default, reuseIdentifier: "row")
        // a reused cell keeps nothing of the row it was
        cell.accessoryView = nil
        cell.accessoryType = .none
        cell.accessibilityCustomActions = nil
        cell.accessibilityValue = nil
        cell.selectionStyle = .default
        switch row {
        case .field:
            break
        case let .find(enabled):
            var content = cell.defaultContentConfiguration()
            content.text = String(localized: "Find Skills")
            content.textProperties.color = enabled ? .tintColor : .tertiaryLabel
            cell.contentConfiguration = content
            cell.accessibilityTraits = enabled ? .button : [.button, .notEnabled]
        case let .skill(candidate, ticked):
            var content = UIListContentConfiguration.subtitleCell()
            // As Wi-Fi's list: the check leads, drawn clear on a row not
            // ticked so every name starts at one edge.
            content.image = UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(weight: .semibold))
            content.imageProperties.tintColor = ticked ? .tintColor : .clear
            content.text = candidate.name
            content.secondaryText = candidate.description
            content.secondaryTextProperties.numberOfLines = 3
            content.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = content
            cell.accessibilityTraits = ticked ? [.button, .selected] : .button
            let count = String(localized: "\(candidate.files.count) files")
            cell.accessibilityValue = count
            cell.accessoryView = accessory(count: count, previewing: candidate)
            cell.accessibilityCustomActions = [previewAction(candidate)]
        case let .unavailable(candidate):
            var content = UIListContentConfiguration.subtitleCell()
            content.text = candidate.name
            content.textProperties.color = .secondaryLabel
            content.secondaryText = Self.reason(candidate)
            content.secondaryTextProperties.numberOfLines = 0
            content.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = content
            cell.accessibilityTraits = .button
            cell.accessoryType = .disclosureIndicator
        }
        return cell
    }

    /// The file count, then the button that previews the skill.
    private func accessory(count: String, previewing candidate: GitHubSkillCandidate) -> UIView {
        let label = UILabel().then {
            $0.text = count
            $0.font = .preferredFont(forTextStyle: .footnote)
            $0.adjustsFontForContentSizeCategory = true
            $0.textColor = .secondaryLabel
            // the row says it as its value
            $0.isAccessibilityElement = false
        }
        let preview = UIButton(type: .detailDisclosure, primaryAction: UIAction { [weak self] _ in
            self?.preview(candidate)
        })
        preview.accessibilityLabel = String(localized: "Preview")
        let stack = UIStackView(arrangedSubviews: [label, preview]).then {
            $0.axis = .horizontal
            $0.alignment = .center
            $0.spacing = 8
        }
        stack.frame.size = stack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        return stack
    }

    private func previewAction(_ candidate: GitHubSkillCandidate) -> UIAccessibilityCustomAction {
        UIAccessibilityCustomAction(name: String(localized: "Preview")) { [weak self] _ in
            self?.preview(candidate)
            return true
        }
    }

    /// Why `candidate` cannot be imported, in a sentence.
    static func reason(_ candidate: GitHubSkillCandidate) -> String {
        switch candidate.problem {
        case .notText?:
            String(localized: "Its SKILL.md is not a text file Apelin can read.")
        case .tooLarge?:
            String(localized: "Too large. A skill can hold up to 2,000 files and 32 MB, with a SKILL.md of up to 1 MB.")
        case .invalidName?:
            String(localized: "“\(candidate.name)” is not a name Apelin can use. A name has up to 64 lowercase letters, digits and single hyphens.")
        case .noDescription?:
            String(localized: "Its SKILL.md has no one-line description, which chats need to know when to use it.")
        case .longDescription?:
            String(localized: "Its description is longer than 1,024 characters.")
        case .userInvokedOnly?:
            String(localized: "It runs only when typed as a command, which Apelin’s chats do not support.")
        case .builtIn?:
            String(localized: "“\(candidate.name)” is the name of a skill built into Apelin.")
        case nil:
            ""
        }
    }

    // MARK: - Choosing

    override func tableView(_: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        switch dataSource.value(at: indexPath) {
        case let .find(enabled)?: enabled
        case .skill?, .unavailable?: !isWorking
        default: false
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch dataSource.value(at: indexPath) {
        case .find?:
            findSkills()
        case let .skill(candidate, _)?:
            guard let scan, !isWorking else { return }
            tickedFolders = GitHubSkillImportPlan.toggling(candidate.folder, in: tickedFolders, candidates: scan.candidates)
            updateRows()
        case let .unavailable(candidate)?:
            preview(candidate)
        default:
            break
        }
    }

    @objc private dynamic func toggleSelectAll() {
        guard let scan, !isWorking else { return }
        let all = GitHubSkillImportPlan.all(of: scan.candidates)
        tickedFolders = all.isSubset(of: tickedFolders) ? [] : all
        updateRows()
    }

    /// The skill's `SKILL.md` as it is, what it brings and what stays.
    private func preview(_ candidate: GitHubSkillCandidate) {
        let summary = candidate.problem == nil ? candidate.description : Self.reason(candidate)
        let page = SkillTextController(
            name: candidate.name,
            summary: summary,
            text: candidate.instructions,
            files: candidate.files.map(\.path).filter { $0 != GitHubSkillLink.skillFileName },
            leftBehind: candidate.leftBehind,
        )
        navigationController?.pushViewController(page, animated: true)
    }

    // MARK: - Scanning

    @objc private dynamic func findSkills() {
        guard !isWorking else { return }
        let text = linkField.text ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let link = GitHubSkillLink.parse(text) else {
            presentNotice(
                title: "Not a GitHub Link",
                message: "Paste a link to a public repository on GitHub, a folder in one, or a SKILL.md.",
            )
            return
        }
        linkField.resignFirstResponder()
        isWorking = true
        updateRows()
        dataSource.beginLoad()
        let scanner = scanner
        let known = listing
        Task { [weak self] in
            guard let self else { return }
            defer {
                isWorking = false
                updateRows()
            }
            do {
                let (listing, scan) = try await ProgressCard.run(
                    title: String(localized: "Finding Skills…"),
                    message: link.fullName,
                    cancellable: true,
                    from: self,
                ) { update in
                    // the page's list, else the agent's, for the built-in names
                    var listing = known
                    if listing == nil {
                        listing = try? await ApelinService.app.agentSkillList()
                    }
                    let builtIns = Set((listing?.skills ?? []).filter { $0.source == .builtIn }.map(\.name))
                    let scan = try await scanner.scan(link, builtInNames: builtIns) { read, total in
                        await update(ProgressCard.Status(
                            subtitle: link.fullName,
                            fraction: total == 0 ? nil : Double(read) / Double(total),
                            count: total == 0 ? nil : String(localized: "\(read.formatted()) of \(total.formatted())"),
                        ))
                    }
                    return (listing, scan)
                }
                self.listing = listing
                guard !scan.candidates.isEmpty else {
                    presentNotice(title: "No Skills Found", message: "No folder at this link holds a SKILL.md.")
                    return
                }
                self.scan = scan
                tickedFolders = GitHubSkillImportPlan.initialSelection(of: scan.candidates)
            } catch is CancellationError {
                return
            } catch {
                presentNotice(title: "Unable to Read from GitHub", message: Self.message(for: error))
            }
        }
    }

    /// What a failure says: Apelin's sentence, then GitHub's own words.
    @objc dynamic static func message(for error: Error) -> String {
        guard let failure = error as? GitHubSkillFailure else { return error.readableMessage }
        let sentence: String
        var words: String?
        switch failure {
        case let .repositoryNotFound(name, said):
            sentence = String(localized: "GitHub has no public repository named “\(name)”. Apelin can import only from public repositories.")
            words = said
        case let .refNotFound(ref, said):
            sentence = String(localized: "The repository has no branch, tag or commit named “\(ref)”.")
            words = said
        case let .pathNotFound(path):
            sentence = String(localized: "The repository has nothing at “\(path)”.")
        case let .rateLimited(resetsAt, retryAfter, said):
            if let resetsAt {
                let time = resetsAt.formatted(date: .omitted, time: .shortened)
                sentence = String(localized: "GitHub limits how often it can be read without signing in. Try again after \(time).")
            } else if let retryAfter, retryAfter > 0 {
                let wait = Duration.seconds(retryAfter).formatted(.units(allowed: [.minutes, .seconds], width: .wide))
                sentence = String(localized: "GitHub asked Apelin to wait. Try again in \(wait).")
            } else {
                sentence = String(localized: "GitHub limits how often it can be read without signing in. Try again in a few minutes.")
            }
            words = said
        case let .refused(_, said):
            sentence = String(localized: "GitHub did not complete the request. Try again later.")
            words = said
        case .tooManyFiles:
            sentence = String(localized: "This repository has too many files to read at once. Paste a link to the folder that holds the skills.")
        case .unreadable:
            sentence = String(localized: "GitHub’s answer could not be read.")
        case .changed:
            sentence = String(localized: "A file downloaded from GitHub did not match the repository. Try again.")
        }
        guard let words else { return sentence }
        return sentence + "\n\n" + String(localized: "GitHub says: “\(words)”")
    }

    // MARK: - Importing

    /// Asks first when an import would replace a skill of the folder.
    @objc private dynamic func confirmImport() {
        guard let scan, !isWorking else { return }
        let chosen = scan.candidates.filter { tickedFolders.contains($0.folder) && $0.problem == nil }
        guard !chosen.isEmpty else { return }
        let existing = (listing?.skills ?? []).filter { $0.source == .user }.compactMap { skill in
            skill.location.map { GitHubSkillImportPlan.Existing(name: skill.name, location: $0) }
        }
        let root = folder.root
        let plan = GitHubSkillImportPlan.replacements(of: chosen.map(\.name), existing: existing) { name in
            (try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(name).path)) != nil
        }
        let replaced = chosen.map(\.name).filter { plan[$0] != nil }
        guard let first = replaced.first else {
            startImport(chosen, from: scan.place, clearing: plan)
            return
        }
        let confirm: () -> Void = { [weak self] in
            self?.startImport(chosen, from: scan.place, clearing: plan)
        }
        if replaced.count == 1 {
            presentConfirmation(
                title: "Replace “\(first)”?",
                message: "The skills folder already has a skill named “\(first)”. Replacing it removes its files.",
                confirmTitle: "Replace",
                destructive: true,
                onConfirm: confirm,
            )
        } else {
            let names = ListFormatter.localizedString(byJoining: replaced)
            presentConfirmation(
                title: "Replace \(replaced.count) Skills?",
                message: "The skills folder already has skills named \(names). Replacing them removes their files.",
                confirmTitle: "Replace",
                destructive: true,
                onConfirm: confirm,
            )
        }
    }

    /// Downloads every chosen skill into a temporary folder, then hands
    /// each to `SkillFolder`, after clearing what `plan` says goes; a cancel
    /// during the download imports nothing.
    private func startImport(
        _ chosen: [GitHubSkillCandidate],
        from place: GitHubSkillPlace,
        clearing plan: [String: GitHubSkillImportPlan.Replacement],
    ) {
        guard !isWorking else { return }
        isWorking = true
        updateRows()
        let scanner = scanner
        let folder = folder
        let total = chosen.reduce(0) { $0 + $1.files.count }
        Task { [weak self] in
            guard let self else { return }
            var placed: [String] = []
            do {
                placed = try await ProgressCard.run(
                    title: String(localized: "Importing Skills…"),
                    message: chosen[0].name,
                    cancellable: true,
                    from: self,
                ) { update in
                    let tally = GitHubSkillTally()
                    let staging = FileManager.default.temporaryDirectory
                        .appendingPathComponent("apelin-github-skills-\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
                    defer { try? FileManager.default.removeItem(at: staging) }
                    for candidate in chosen {
                        let name = candidate.name
                        try await scanner.download(candidate, from: place, into: staging.appendingPathComponent(name, isDirectory: true)) { _ in
                            let done = await tally.add()
                            await update(ProgressCard.Status(
                                subtitle: name,
                                fraction: Double(done) / Double(max(total, 1)),
                                count: String(localized: "\(done.formatted()) of \(total.formatted())"),
                            ))
                        }
                    }
                    try Task.checkCancellation()
                    try DataFolder.app.makeLevels(to: folder.root)
                    return try await Task.detached {
                        try Self.place(chosen, from: staging, clearing: plan, into: folder)
                    }.value
                }
                isWorking = false
                SPIndicator.present(title: String(localized: "Imported"), preset: .done, haptic: .success)
                let onImport = onImport
                navigationController?.dismiss(animated: true) {
                    onImport?(placed)
                }
            } catch is CancellationError {
                isWorking = false
                updateRows()
            } catch {
                isWorking = false
                updateRows()
                onImport?([])
                presentNotice(title: "Unable to Import Skills", message: Self.importMessage(for: error))
            }
        }
    }

    /// Clears what `plan` says goes for each skill, then moves it in from
    /// `staging`; the places it took, in order.
    private nonisolated static func place(
        _ chosen: [GitHubSkillCandidate],
        from staging: URL,
        clearing plan: [String: GitHubSkillImportPlan.Replacement],
        into folder: SkillFolder,
    ) throws -> [String] {
        try chosen.map { candidate in
            let replacement = plan[candidate.name]
            for other in replacement?.elsewhere ?? [] {
                try folder.remove(other)
            }
            let staged = staging.appendingPathComponent(candidate.name, isDirectory: true)
            return try folder.add(staged, replacing: replacement?.atPlace ?? false)
        }
    }

    @objc dynamic static func importMessage(for error: Error) -> String {
        switch error {
        case let SkillFolder.Failure.exists(location):
            String(localized: "The skills folder already has “\(location)”. Find the skills again, then import.")
        case SkillFolder.Failure.tooLarge:
            String(localized: "A skill can hold up to 2,000 files and 32 MB.")
        default:
            message(for: error)
        }
    }
}

/// How many files an import has written, counted from its downloads.
private actor GitHubSkillTally {
    private var done = 0

    func add() -> Int {
        done += 1
        return done
    }
}
