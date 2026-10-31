import Then
import UIKit

extension LogViewerController {
    func setupNavigationItems() {
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis"),
            menu: UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
                completion(self?.createMenu().children ?? [])
            }]),
        ).then { $0.accessibilityLabel = String(localized: "More") }
    }

    private func createMenu() -> UIMenu {
        let levelActions = JournalLevel.allCases.map { level in
            UIAction(
                title: Self.name(of: level),
                state: selectedLevels.contains(level) ? .on : .off,
                handler: { [weak self] _ in
                    self?.toggleLevel(level)
                },
            )
        }
        let levelMenu = UIMenu(
            title: String(localized: "Filter by Level"),
            image: UIImage(systemName: "slider.horizontal.3"),
            children: levelActions,
        )

        var categoryActions: [UIAction] = []
        let categories = allCategories
        if !categories.isEmpty {
            categoryActions.append(UIAction(
                title: String(localized: "All Categories"),
                state: selectedCategories.isEmpty ? .on : .off,
                handler: { [weak self] _ in
                    self?.selectedCategories.removeAll()
                    self?.applyFilters(stickToBottom: false)
                },
            ))
            categoryActions.append(contentsOf: categories.sorted().map { category in
                UIAction(
                    title: category,
                    state: selectedCategories.contains(category) ? .on : .off,
                    handler: { [weak self] _ in
                        self?.toggleCategory(category)
                    },
                )
            })
        }
        let emptyCategories = [UIAction(title: String(localized: "No Categories"), attributes: .disabled) { _ in }]
        let categoryMenu = UIMenu(
            title: String(localized: "Filter by Category"),
            image: UIImage(systemName: "tag"),
            children: categoryActions.isEmpty ? emptyCategories : categoryActions,
        )

        let onlyFailuresAction = UIAction(
            title: String(localized: "Errors Only"),
            image: UIImage(systemName: "exclamationmark.triangle"),
            attributes: .keepsMenuPresented,
            state: selectedLevels == [.error, .critical] ? .on : .off,
            handler: { [weak self] action in
                guard let self else { return }
                selectedLevels = selectedLevels == [.error, .critical]
                    ? [.verbose, .info, .warning, .error, .critical]
                    : [.error, .critical]
                action.state = selectedLevels == [.error, .critical] ? .on : .off
                applyFilters(stickToBottom: false)
            },
        )

        var fileActions = [UIAction(
            title: String(localized: "Share"),
            image: UIImage(systemName: "square.and.arrow.up"),
            handler: { [weak self] _ in
                self?.shareLog()
            },
        )]
        // an earlier launch's file is deleted from the list instead
        if isCurrent {
            fileActions.append(UIAction(
                title: String(localized: "Clear"),
                image: UIImage(systemName: "trash"),
                attributes: .destructive,
                handler: { [weak self] _ in
                    self?.clearLog()
                },
            ))
        }

        return UIMenu(children: [
            levelMenu,
            categoryMenu,
            UIMenu(options: .displayInline, children: [onlyFailuresAction]),
            UIMenu(options: .displayInline, children: fileActions),
        ])
    }

    /// The level as the filter menu and VoiceOver name it.
    static func name(of level: JournalLevel) -> String {
        switch level {
        case .verbose: String(localized: "Verbose")
        case .info: String(localized: "Info")
        case .warning: String(localized: "Warning")
        case .error: String(localized: "Error")
        case .critical: String(localized: "Critical")
        }
    }

    private func toggleLevel(_ level: JournalLevel) {
        if selectedLevels.contains(level) {
            selectedLevels.remove(level)
        } else {
            selectedLevels.insert(level)
        }
        applyFilters(stickToBottom: false)
    }

    private func toggleCategory(_ category: String) {
        if selectedCategories.contains(category) {
            selectedCategories.remove(category)
        } else {
            selectedCategories.insert(category)
        }
        applyFilters(stickToBottom: false)
    }

    /// Shares the log as a file. A support report is a `.log` attachment, not
    /// half a megabyte pasted into a message field.
    private func shareLog() {
        let text = logText()
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(file.shareName)
        let items: [Any] = if (try? text.write(to: copy, atomically: true, encoding: .utf8)) != nil {
            [copy]
        } else {
            [text]
        }
        let sheet = UIActivityViewController(activityItems: items, applicationActivities: nil)
        sheet.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        present(sheet, animated: true)
    }

    /// Hides what the running launch wrote so far; the file keeps it, and
    /// Share sends only what is shown after this.
    private func clearLog() {
        hiddenPrefixCount = Self.text(of: file, hiding: 0).count
        reload(growing: false)
    }

    func tableView(
        _: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point _: CGPoint,
    ) -> UIContextMenuConfiguration? {
        guard let logLine = dataSource.itemIdentifier(for: indexPath)?.line else { return nil }

        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            let copyAction = UIAction(
                title: String(localized: "Copy"),
                image: UIImage(systemName: "doc.on.doc"),
            ) { _ in
                UIPasteboard.general.string = logLine.fullText
            }

            let copyMessageAction = UIAction(
                title: String(localized: "Copy Message"),
                image: UIImage(systemName: "text.quote"),
            ) { _ in
                UIPasteboard.general.string = logLine.message
            }

            return UIMenu(children: [copyAction, copyMessageAction])
        }
    }
}
