import UIKit
import UniformTypeIdentifiers
import YoyoCore

/// The kit's pages for a computer's clipboard.
public enum YoyoClipboard {
    /// The Clipboard page for `backend`'s computer: push it, or present it in a navigation controller (give it a close
    /// button then). `computer`: whose words it uses (the Mac's, or another computer's).
    @MainActor public static func makePage(backend: any YoyoBackend, computer: YoyoComputer) -> UIViewController {
        ClipboardViewController(backend: backend, host: computer)
    }
}

/// The computer's clipboard (PROTOCOL.md「剪贴板」): an "On your Mac" card with what it has copied, live (text up to 12
/// lines — tap for all of it —, an image's thumbnail, a files item's rows), with Copy / Share / Save under it; and
/// "Send to Mac": a paste control for what the phone has copied, Photos… and Files… pickers (when the backend sends
/// files), which land on the computer's clipboard (files in its Downloads too). An app pushes it from its own row; the
/// Screen page's "Copy from Mac" opens it as a sheet for a files item. Another computer than a Mac: "computer" in the
/// words (`host`).
final class ClipboardViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private enum Row: Hashable { case card, file(Int), actions, paste, photos, files }

    private let backend: any YoyoBackend
    /// Whose clipboard: a Mac's, or another computer's (only the words differ).
    private let host: YoyoComputer
    private let state: YoyoClipboardState
    private var status: ClipboardStatus?
    private var error: Error?
    /// The server has no clipboard feature (404): the page says so (the row that opens it is hidden anyway).
    private var unsupported = false
    /// The text card shows every line.
    private var expanded = false
    /// The current image item's picture (nil while loading; `for` = the changeCount it belongs to).
    private var thumbnail: (image: UIImage, for: Int)?
    private var thumbnailLoading: Int?
    /// A text item known from the event only: its text asked for once per changeCount.
    private var textAsked: Int?
    /// A transfer under way (the bar shows it; buttons wait).
    private var busy: (text: String, fraction: Double?)? { didSet { updateBusy(changed: (busy == nil) != (oldValue == nil)) } }
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let toast = ToastView()
    /// Photos… / Files…
    private let picker = ClipboardPicker()

    init(backend: any YoyoBackend, host: YoyoComputer = .mac) {
        self.backend = backend
        self.host = host
        state = YoyoClipboardState.of(backend)
        super.init(nibName: nil, bundle: nil)
        title = L("Clipboard")
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: View

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.groupedBackground
        view.accessibilityIdentifier = "clipboard"
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.backButtonDisplayMode = .minimal

        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.sectionHeaderTopPadding = 8
        tableView.keyboardDismissMode = .onDrag
        tableView.accessibilityIdentifier = "clipboard.list"
        tableView.register(ClipboardCardCell.self, forCellReuseIdentifier: "card")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
        tableView.register(ClipboardActionsCell.self, forCellReuseIdentifier: "actions")
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self, weak refresh] _ in
            self?.load(force: true)
            refresh?.endRefreshing()
        }, for: .valueChanged)
        tableView.refreshControl = refresh

        toast.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toast)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toast.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            toast.widthAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.widthAnchor, constant: -32),
            toast.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
        ])

        // what the phone has copied, pasted onto the Mac (`paste(itemProviders:)`)
        pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [
            UTType.plainText.identifier, UTType.url.identifier, UTType.image.identifier, UTType.fileURL.identifier,
        ])

        state.observe(self) { [weak self] _ in self?.render() }
        render()
        load()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        state.refresh()
    }

    private func load(force: Bool = false) {
        if force { Task { try? await state.load(force: true) } } else { state.refresh() }
    }

    private func render() {
        unsupported = state.isUnsupported
        error = state.error
        let before = status
        status = state.status
        if let s = status {
            if before?.item?.changeCount != s.item?.changeCount { expanded = false }
            // the event carries no text: ask once (the answer lands here again, with it)
            if let item = s.item, item.kind == .text, item.text == nil, textAsked != item.changeCount {
                textAsked = item.changeCount
                load(force: true)
            }
            loadThumbnailIfNeeded(s)
        }
        tableView.reloadData()
        updateEmptyState()
    }

    private func updateEmptyState() {
        if unsupported {
            var c = UIContentUnavailableConfiguration.empty()
            c.image = UIImage(systemName: "doc.on.clipboard")
            c.text = L("Clipboard not available")
            c.secondaryText = L("This computer can’t share its clipboard.")
            contentUnavailableConfiguration = c
        } else if status == nil, let error = state.error {
            var c = UIContentUnavailableConfiguration.empty()
            c.image = UIImage(systemName: "exclamationmark.triangle")
            c.text = L("Couldn’t read the clipboard")
            c.secondaryText = ClipboardTransfer.message(error)
            var b = UIButton.Configuration.gray()
            b.title = L("Retry")
            c.button = b
            c.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.load(force: true) }
            contentUnavailableConfiguration = c
        } else if status == nil {
            contentUnavailableConfiguration = UIContentUnavailableConfiguration.loading()
        } else {
            contentUnavailableConfiguration = nil
        }
        tableView.isHidden = contentUnavailableConfiguration != nil
    }

    private func loadThumbnailIfNeeded(_ s: ClipboardStatus) {
        guard let item = s.item, item.kind == .image else { return }
        let n = item.changeCount
        guard thumbnail?.for != n, thumbnailLoading != n else { return }
        thumbnailLoading = n
        let backend = backend
        Task { [weak self] in
            let image: UIImage?
            do {
                let data = try await ClipboardTransfer.image(changeCount: n, backend: backend)
                image = await Task.detached { ClipboardFiles.thumbnail(data: data, maxPixel: 1400) }.value
            } catch {
                image = nil
            }
            guard let self, self.thumbnailLoading == n else { return }
            self.thumbnailLoading = nil
            if let image {
                self.thumbnail = (image, n)
                self.tableView.reloadRows(at: [IndexPath(row: 0, section: 0)], with: .fade)
            }
        }
    }

    /// The bar shows a transfer under way ("Uploading 3 files… 40%"), like My Computer's uploads. `changed`: a transfer
    /// began or ended (the buttons and rows follow; a progress tick alone leaves them, the paste control included).
    private func updateBusy(changed: Bool) {
        if changed, isViewLoaded { tableView.reloadSections(IndexSet(integersIn: 0..<2), with: .none) }
        guard let busy else {
            if navigationItem.rightBarButtonItem?.accessibilityIdentifier == "clipboard.busy" { navigationItem.rightBarButtonItem = nil }
            return
        }
        let spin = UIActivityIndicatorView(style: .medium)
        spin.startAnimating()
        let label = UILabel()
        label.text = busy.fraction.map { "\(busy.text) \(Int($0 * 100))%" } ?? busy.text
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = Theme.secondaryText
        let stack = UIStackView(arrangedSubviews: [spin, label])
        stack.spacing = 8
        let item = UIBarButtonItem(customView: stack)
        item.hidesSharedBackground = true
        item.accessibilityIdentifier = "clipboard.busy"
        navigationItem.rightBarButtonItem = item
    }

    /// A short notice: the host's (`YoyoHost.toast`) or the page's own glass toast.
    private func notify(_ text: String) {
        if let toast = YoyoHost.current.toast { toast(text, self) } else { self.toast.show(text) }
    }

    // MARK: Rows

    private var rows: [[Row]] {
        var card: [Row] = [.card]
        if let item = status?.item, item.kind == .files { card += item.summary.files.indices.map(Row.file) }
        card.append(.actions)
        return [card, backend.sendsClipboardFiles ? [.paste, .photos, .files] : [.paste]]
    }

    private var enabled: ClipboardActions.Enabled { ClipboardActions.enabled(status) }
    private var canSend: Bool { enabled.send && busy == nil }

    func numberOfSections(in tableView: UITableView) -> Int { rows.count }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows[section].count }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? host.onYourComputer : host.sendTitle
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard section == 1 else { return nil }
        if let status, !status.available { return status.reason ?? L("Clipboard unavailable") }
        return host.sendFooter
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = rows[indexPath.section][indexPath.row]
        switch row {
        case .card:
            let cell = tableView.dequeueReusableCell(withIdentifier: "card", for: indexPath) as! ClipboardCardCell
            cell.configure(status, thumbnail: status?.item.flatMap { thumbnail?.for == $0.changeCount ? thumbnail?.image : nil }, expanded: expanded,
                           width: tableView.bounds.width - 72, host: host)
            return cell
        case .file(let i):
            let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
            var c = UIListContentConfiguration.subtitleCell()
            let f = status?.item?.summary.files[i]
            c.text = f?.name
            c.textProperties.lineBreakMode = .byTruncatingMiddle
            c.secondaryText = f?.dir == true ? host.folderOnComputer
                : f?.size.map { Int64($0).formatted(.byteCount(style: .file).locale(YoyoL10n.locale)) }
            c.secondaryTextProperties.color = Theme.tertiaryText
            c.secondaryTextProperties.font = .preferredFont(forTextStyle: .caption1)
            c.image = UIImage(systemName: f?.dir == true ? "folder.fill" : ClipboardFiles.symbol(name: f?.name ?? ""))
            c.imageProperties.tintColor = Theme.secondaryText
            c.imageProperties.reservedLayoutSize = CGSize(width: 30, height: UIListContentConfiguration.ImageProperties.standardDimension)
            cell.contentConfiguration = c
            cell.backgroundColor = Theme.cellBackground
            cell.selectionStyle = .none
            cell.accessoryView = nil
            cell.accessibilityIdentifier = "clipboard.file.\(i)"
            return cell
        case .actions:
            let cell = tableView.dequeueReusableCell(withIdentifier: "actions", for: indexPath) as! ClipboardActionsCell
            var e = enabled
            if busy != nil { e = ClipboardActions.Enabled() }
            cell.configure(e, copyTitle: L("Copy"), saveTitle: status?.kind == .image ? L("Save to Photos") : L("Save to Files"))
            cell.onCopy = { [weak self] in self?.copyToPhone() }
            cell.onShare = { [weak self] in self?.share() }
            cell.onSave = { [weak self] in self?.save() }
            return cell
        case .paste:
            let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
            var c = UIListContentConfiguration.subtitleCell()
            c.text = host.pasteLabel
            c.secondaryText = L("What you copied on this iPhone: text, a link, an image or files")
            c.secondaryTextProperties.color = Theme.tertiaryText
            c.secondaryTextProperties.font = .preferredFont(forTextStyle: .caption1)
            c.image = UIImage(systemName: "arrow.right.doc.on.clipboard")
            c.imageProperties.tintColor = canSend ? Theme.text : Theme.tertiaryText
            c.textProperties.color = canSend ? Theme.text : Theme.tertiaryText
            c.imageProperties.reservedLayoutSize = CGSize(width: 30, height: UIListContentConfiguration.ImageProperties.standardDimension)
            cell.contentConfiguration = c
            cell.backgroundColor = Theme.cellBackground
            cell.selectionStyle = .none
            let config = UIPasteControl.Configuration()
            config.displayMode = .labelOnly
            config.cornerStyle = .capsule
            config.baseBackgroundColor = Theme.coral
            config.baseForegroundColor = .white
            let control = UIPasteControl(configuration: config)
            control.target = self
            control.isEnabled = canSend
            control.accessibilityIdentifier = "clipboard.paste"
            control.sizeToFit()
            cell.accessoryView = control
            cell.accessibilityIdentifier = "clipboard.pasteRow"
            return cell
        case .photos, .files:
            let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
            var c = UIListContentConfiguration.cell()
            c.text = row == .photos ? L("Photos…") : L("Files…")
            c.image = UIImage(systemName: row == .photos ? "photo.on.rectangle" : "folder")
            c.imageProperties.tintColor = canSend ? Theme.text : Theme.tertiaryText
            c.textProperties.color = canSend ? Theme.text : Theme.tertiaryText
            c.imageProperties.reservedLayoutSize = CGSize(width: 30, height: UIListContentConfiguration.ImageProperties.standardDimension)
            cell.contentConfiguration = c
            cell.backgroundColor = Theme.cellBackground
            cell.selectionStyle = canSend ? .default : .none
            cell.accessoryView = nil
            cell.accessibilityTraits = .button
            cell.accessibilityIdentifier = row == .photos ? "clipboard.photos" : "clipboard.files"
            return cell
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch rows[indexPath.section][indexPath.row] {
        case .card:
            // a long text: all of it, then back to its first lines
            guard status?.kind == .text else { return }
            expanded.toggle()
            tableView.reloadRows(at: [indexPath], with: .automatic)
        case .photos: if canSend { pickPhotos() }
        case .files: if canSend { pickFiles() }
        case .file, .actions, .paste: break
        }
    }

    // MARK: Copy / Share / Save (the Mac's item onto the phone)

    private func copyToPhone() {
        guard let status, let item = status.item, busy == nil else { return }
        switch item.kind {
        case .text:
            guard let text = item.text else { load(force: true); return }
            ClipboardTransfer.putOnPhone(text: text)
            UINotificationFeedbackGenerator(view: view).notificationOccurred(.success)
            notify(L("Copied"))
        case .image:
            withImage(item) { data in
                ClipboardTransfer.putOnPhone(imageData: data)
                UINotificationFeedbackGenerator(view: self.view).notificationOccurred(.success)
                self.notify(L("Copied"))
            }
        default: break
        }
    }

    private func share() {
        guard let status, let item = status.item, busy == nil else { return }
        switch item.kind {
        case .text:
            guard let text = item.text else { load(force: true); return }
            present(activity: [text])
        case .image:
            withImage(item) { data in self.present(activity: [UIImage(data: data) ?? data]) }
        case .files:
            withFiles(item) { urls in self.present(activity: urls) }
        default: break
        }
    }

    private func save() {
        guard let status, let item = status.item, busy == nil else { return }
        switch item.kind {
        case .image:
            withImage(item) { data in
                do {
                    try await ClipboardTransfer.saveToPhotos(data)
                    UINotificationFeedbackGenerator(view: self.view).notificationOccurred(.success)
                    self.notify(L("Saved to Photos"))
                } catch {
                    self.notify(ClipboardTransfer.message(error))
                }
            }
        case .files:
            withFiles(item) { urls in
                let exporter = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
                exporter.shouldShowFileExtensions = true
                self.present(exporter, animated: true)
            }
        default: break
        }
    }

    /// The image's bytes (cached), then `then`. A 409 (the Mac copied something else meanwhile) refetches the status
    /// and tries once more with the new item if it is still an image.
    private func withImage(_ item: ClipboardItem, retried: Bool = false, then: @escaping @MainActor (Data) async -> Void) {
        busy = (L("Loading…"), nil)
        let backend = backend
        Task { [weak self] in
            do {
                let data = try await ClipboardTransfer.image(changeCount: item.changeCount, backend: backend)
                guard let self else { return }
                self.busy = nil
                await then(data)
            } catch {
                guard let self else { return }
                self.busy = nil
                if YoyoHost.current.handleError(error) { return }
                if case YoyoError.http(409, _) = error, !retried {
                    if let fresh = try? await self.state.load(force: true), let next = fresh.item, next.kind == .image {
                        self.withImage(next, retried: true, then: then)
                    }
                    return
                }
                self.notify(ClipboardTransfer.message(error))
            }
        }
    }

    /// The regular files downloaded (the bar counting), then `then` with their temp URLs.
    private func withFiles(_ item: ClipboardItem, retried: Bool = false, then: @escaping @MainActor ([URL]) -> Void) {
        let regular = item.summary.files.filter { !$0.dir }
        guard !regular.isEmpty else { return }
        let limit = backend.clipboardFileLimit
        if let big = regular.first(where: { ($0.size ?? 0) > limit }) {
            notify(L("\(big.name) is too large (max \(ClipboardActions.sizeText(limit))).")); return
        }
        busy = (L("Downloading 1 of \(regular.count)…"), 0)
        let backend = backend
        Task { [weak self] in
            do {
                let urls = try await ClipboardTransfer.downloadFiles(item, backend: backend) { done, total, fraction in
                    self?.busy = (L("Downloading \(min(done + 1, total)) of \(total)…"), fraction)
                }
                guard let self else { return }
                self.busy = nil
                if regular.count < item.summary.files.count { self.notify(L("Folders were left out.")) }
                then(urls)
            } catch {
                guard let self else { return }
                self.busy = nil
                if YoyoHost.current.handleError(error) { return }
                if case YoyoError.http(409, _) = error, !retried {
                    if let fresh = try? await self.state.load(force: true), let next = fresh.item, next.kind == .files {
                        self.withFiles(next, retried: true, then: then)
                    }
                    return
                }
                self.notify(ClipboardTransfer.message(error))
            }
        }
    }

    private func present(activity items: [Any]) {
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        if let cell = tableView.cellForRow(at: IndexPath(row: rows[0].count - 1, section: 0)) {
            vc.popoverPresentationController?.sourceView = cell
        } else {
            vc.popoverPresentationController?.sourceView = view
        }
        present(vc, animated: true)
    }

    // MARK: Send to Mac

    /// The paste control's paste (`UIPasteConfigurationSupporting`).
    override func paste(itemProviders: [NSItemProvider]) {
        guard canSend else { return }
        busy = (L("Reading…"), nil)
        Task { [weak self] in
            let content = await ClipboardTransfer.content(from: itemProviders)
            guard let self else { return }
            self.busy = nil
            do { self.send(try ClipboardActions.payload(content, limit: self.backend.clipboardFileLimit)) }
            catch { self.notify(error.localizedDescription) }
        }
    }

    private func pickFiles() { pick(.files) }

    private func pickPhotos() { pick(.photos) }

    /// The picked files read (the bar counting), then sent as one item.
    private func pick(_ source: ClipboardPicker.Source) {
        guard busy == nil, !picker.reading else { return }
        picker.limit = backend.clipboardFileLimit
        picker.onProgress = { [weak self] text in self?.busy = text.map { ($0, nil) } }
        picker.onPicked = { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let files):
                do { self.send(try ClipboardActions.payload(ClipboardActions.PhoneContent(files: files), limit: self.backend.clipboardFileLimit)) }
                catch { self.notify(error.localizedDescription) }
            case .failure(let error):
                self.notify(self.picker.message(error))
            }
        }
        picker.present(source, from: self)
    }

    /// `PUT /clipboard`; the answer is the new status.
    private func send(_ payload: ClipboardActions.Payload) {
        guard busy == nil else { return }
        let count: Int
        switch payload {
        case .text: count = 0; busy = (L("Copying…"), nil)
        case .files(let files): count = files.count; busy = (L("Uploading \(files.count) files…"), 0)
        }
        let backend = backend
        Task { [weak self] in
            do {
                let r = try await ClipboardTransfer.send(payload, backend: backend) { f in
                    Task { @MainActor in if count > 0 { self?.busy = (L("Uploading \(count) files…"), f) } }
                }
                guard let self else { return }
                self.busy = nil
                self.state.set(r.status)
                UINotificationFeedbackGenerator(view: self.view).notificationOccurred(.success)
                self.notify(ClipboardTransfer.sentMessage(payload, r, computer: self.host))
            } catch {
                guard let self else { return }
                self.busy = nil
                if YoyoHost.current.handleError(error) { return }
                if case YoyoError.http(503, _) = error { self.load(force: true) }
                self.notify(ClipboardTransfer.failureMessage(error, payload, limit: self.backend.clipboardFileLimit))
            }
        }
    }
}

// MARK: - Cells

/// The "On your Mac" card: the kind's glyph and title, the content (text / thumbnail / a quiet state line), the footer.
final class ClipboardCardCell: UITableViewCell {
    private let glyph = UIImageView()
    private let titleLabel = UILabel()
    private let body = UILabel()
    private let picture = UIImageView()
    private let footer = UILabel()
    private var pictureHeight: NSLayoutConstraint!

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = Theme.cellBackground
        selectionStyle = .none
        accessibilityIdentifier = "clipboard.card"
        glyph.contentMode = .scaleAspectFit
        glyph.tintColor = Theme.secondaryText
        glyph.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = Theme.text
        titleLabel.numberOfLines = 2
        let head = UIStackView(arrangedSubviews: [glyph, titleLabel])
        head.spacing = 10
        head.alignment = .center
        body.adjustsFontForContentSizeCategory = true
        body.textColor = Theme.text
        body.lineBreakMode = .byTruncatingTail
        picture.contentMode = .scaleAspectFit
        picture.clipsToBounds = true
        picture.layer.cornerRadius = 8
        picture.layer.cornerCurve = .continuous
        picture.backgroundColor = Theme.fillFaint
        picture.accessibilityIgnoresInvertColors = true
        pictureHeight = picture.heightAnchor.constraint(equalToConstant: 200)
        pictureHeight.isActive = true
        footer.font = .preferredFont(forTextStyle: .caption1)
        footer.adjustsFontForContentSizeCategory = true
        footer.textColor = Theme.tertiaryText
        footer.numberOfLines = 1
        let stack = UIStackView(arrangedSubviews: [head, body, picture, footer])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor, constant: -4),
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            glyph.widthAnchor.constraint(equalToConstant: 26),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// `width`: the content width the picture gets (its height follows the image's aspect, 80…260 pt).
    func configure(_ status: ClipboardStatus?, thumbnail: UIImage?, expanded: Bool, width: CGFloat, host: YoyoComputer = .mac) {
        let kind = status?.kind ?? .other
        let symbol: String
        switch kind {
        case .text: symbol = "text.alignleft"
        case .image: symbol = "photo"
        case .files: symbol = "doc.on.doc"
        case .concealed: symbol = "eye.slash"
        case .empty: symbol = "clipboard"
        case .other: symbol = status?.available == false ? "exclamationmark.triangle" : "questionmark.square.dashed"
        }
        glyph.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .medium))
        body.isHidden = true
        picture.isHidden = true
        footer.isHidden = true
        accessibilityTraits = .staticText
        guard let status else { titleLabel.text = nil; return }
        guard status.available else {
            titleLabel.text = L("Clipboard unavailable")
            body.text = status.reason
            body.font = .preferredFont(forTextStyle: .subheadline)
            body.textColor = Theme.secondaryText
            body.numberOfLines = 0
            body.isHidden = status.reason == nil
            return
        }
        guard let item = status.item, item.kind != .empty else {
            titleLabel.text = L("Empty")
            body.text = host.copySomething
            body.font = .preferredFont(forTextStyle: .subheadline)
            body.textColor = Theme.secondaryText
            body.numberOfLines = 0
            body.isHidden = false
            return
        }
        let s = item.summary
        footer.text = ClipboardActions.footer(s, host: host)
        footer.isHidden = false
        switch s.kind {
        case .text:
            titleLabel.text = L("Text")
            if let size = s.size { titleLabel.text = L("Text · \(Int64(size).formatted(.byteCount(style: .file).locale(YoyoL10n.locale)))") }
            let text = item.text ?? s.preview
            body.text = text + (item.truncated ? "\n…" : "")
            let mono = ClipboardActions.looksLikeCode(text)
            body.font = mono ? UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .monospacedSystemFont(ofSize: 13, weight: .regular))
                : .preferredFont(forTextStyle: .body)
            body.textColor = Theme.text
            body.numberOfLines = expanded ? 0 : 12
            body.isHidden = false
            accessibilityTraits = .button
            accessibilityHint = expanded ? L("Shows the first lines") : L("Shows the whole text")
        case .image:
            titleLabel.text = ClipboardActions.previewLine(s)
            picture.image = thumbnail
            picture.isHidden = false
            if let image = thumbnail, image.size.width > 0, width > 0 {
                pictureHeight.constant = min(260, max(80, width * image.size.height / image.size.width))
            } else {
                pictureHeight.constant = 200
            }
        case .files:
            titleLabel.text = L("\(s.files.count + s.moreFiles) files")
            if let size = s.size, size > 0 {
                titleLabel.text = L("\(s.files.count + s.moreFiles) files · \(Int64(size).formatted(.byteCount(style: .file).locale(YoyoL10n.locale)))")
            }
            if s.moreFiles > 0 {
                body.text = L("and \(s.moreFiles) more not listed")
                body.font = .preferredFont(forTextStyle: .subheadline)
                body.textColor = Theme.secondaryText
                body.numberOfLines = 1
                body.isHidden = false
            }
        case .concealed:
            titleLabel.text = L("Hidden (password manager)")
            body.text = L("A password manager marked this item hidden; it can’t be read from here.")
            body.font = .preferredFont(forTextStyle: .subheadline)
            body.textColor = Theme.secondaryText
            body.numberOfLines = 0
            body.isHidden = false
        case .empty, .other:
            titleLabel.text = ClipboardActions.previewLine(s)
        }
    }
}

/// Copy · Share · Save under the card.
final class ClipboardActionsCell: UITableViewCell {
    var onCopy: (() -> Void)?
    var onShare: (() -> Void)?
    var onSave: (() -> Void)?
    private let copy = UIButton(configuration: .filled())
    private let share = UIButton(configuration: .filled())
    private let save = UIButton(configuration: .filled())

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = Theme.cellBackground
        selectionStyle = .none
        for (b, symbol, id, action) in [(copy, "doc.on.doc", "clipboard.copy", #selector(copyTapped)),
                                        (share, "square.and.arrow.up", "clipboard.share", #selector(shareTapped)),
                                        (save, "square.and.arrow.down", "clipboard.save", #selector(saveTapped))] {
            var c = UIButton.Configuration.filled()
            c.cornerStyle = .medium
            c.baseBackgroundColor = Theme.sheetControl
            c.baseForegroundColor = Theme.text
            c.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .medium))
            c.imagePlacement = .top
            c.imagePadding = 6
            c.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attrs in
                var a = attrs
                a.font = UIFont.preferredFont(forTextStyle: .caption1)
                return a
            }
            c.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 6, bottom: 8, trailing: 6)
            b.configuration = c
            b.accessibilityIdentifier = id
            b.addTarget(self, action: action, for: .primaryActionTriggered)
        }
        let stack = UIStackView(arrangedSubviews: [copy, share, save])
        stack.distribution = .fillEqually
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ e: ClipboardActions.Enabled, copyTitle: String, saveTitle: String) {
        copy.configuration?.title = copyTitle
        share.configuration?.title = L("Share")
        save.configuration?.title = saveTitle
        copy.isEnabled = e.copy
        share.isEnabled = e.share
        save.isEnabled = e.save
    }

    @objc private func copyTapped() { onCopy?() }
    @objc private func shareTapped() { onShare?() }
    @objc private func saveTapped() { onSave?() }
}
