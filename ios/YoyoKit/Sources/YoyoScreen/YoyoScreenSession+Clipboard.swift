import UIKit
import YoyoClipboard
import YoyoCore

// The clipboard's moves of a screen session (PROTOCOL.md「剪贴板」): Paste on Mac (the phone's clipboard onto the
// computer's, then the paste shortcut while the phone holds control), Copy from Mac (the computer's text / image onto
// the phone's clipboard; files open the Clipboard page), photos and files onto the computer's clipboard. The keyboard's
// keys, the page's clipboard menu and its hints all come here.
extension YoyoScreenSession {
    /// What this run of the app has shown or done with either clipboard (the dot, the hints).
    private static var clipboardMarksByScope: [String: ScreenClipboardMarks] = [:]
    /// This account's marks (each account's computer has its own clipboard and change counts).
    var clipboardMarks: ScreenClipboardMarks {
        get { Self.clipboardMarksByScope[backend.cacheScope] ?? ScreenClipboardMarks() }
        set { Self.clipboardMarksByScope[backend.cacheScope] = newValue }
    }

    /// The phone's clipboard onto the computer's, then pastes there (in control: at once; watching, it takes the screen
    /// first as `requestInput` says, else it only says so).
    public func pasteOnComputer() { clipboardKey(.pasteOnMac) }

    /// The computer's clipboard onto the phone's (text, an image; files open the Clipboard page).
    public func copyFromComputer() { clipboardKey(.copyFromMac) }

    func clipboardKey(_ key: ScreenClipboardKey) {
        guard !clipboardBusy else { return }
        let backend = backend
        switch key {
        case .pasteOnMac:
            let payload: ClipboardActions.Payload
            do { payload = try ClipboardActions.payload(ClipboardTransfer.phoneContent(), limit: backend.clipboardFileLimit) }
            catch { notice(.message(error.localizedDescription)); return }
            clipboardMarks.phone = UIPasteboard.general.changeCount
            changed(.clipboard)
            clipboardBusy = true
            Task { [weak self] in
                defer { self?.clipboardBusy = false }
                do {
                    let r = try await ClipboardTransfer.send(payload, backend: backend)
                    guard let self else { return }
                    YoyoClipboardState.of(backend).set(r.status)
                    if self.inputWouldGo {
                        // a paste into the computer is input: watching, it takes the screen first
                        self.requestInput { [weak self] in
                            guard let self else { return }
                            self.sendPasteShortcut()
                            self.notice(.message(self.computer.pasted))
                        }
                    } else {
                        self.notice(.message(self.computer.copiedTakeControl))
                    }
                } catch {
                    if YoyoHost.current.handleError(error) { return }
                    self?.notice(.message(ScreenSession.message(error)))
                }
            }
        case .copyFromMac:
            clipboardBusy = true
            Task { [weak self] in
                defer { self?.clipboardBusy = false }
                do {
                    let status = try await YoyoClipboardState.of(backend).load(force: true)
                    guard let self else { return }
                    if let count = status.item?.changeCount { clipboardMarks.mac = count }
                    switch ClipboardActions.copyFromMac(status) {
                    case .text(let s):
                        ClipboardTransfer.putOnPhone(text: s)
                        self.notice(.message(self.computer.copiedFrom))
                    case .image(let changeCount):
                        ClipboardTransfer.putOnPhone(imageData: try await ClipboardTransfer.image(changeCount: changeCount, backend: backend))
                        self.notice(.message(self.computer.copiedFrom))
                    case .openFiles:
                        self.openClipboardPage()
                    case .concealed: self.notice(.message(self.computer.clipboardConcealed))
                    case .empty: self.notice(.message(self.computer.clipboardEmptyMessage))
                    case .unavailable(let reason): self.notice(.message(reason ?? L("Clipboard unavailable")))
                    case .nothing: self.notice(.message(self.computer.clipboardNothing))
                    }
                    // what the computer sent is no news for Paste on Mac
                    clipboardMarks.phone = UIPasteboard.general.changeCount
                    self.changed(.clipboard)
                } catch {
                    if YoyoHost.current.handleError(error) { return }
                    self?.notice(.message(ScreenSession.message(error)))
                }
            }
        }
    }

    /// The Clipboard page as a sheet over the presenting view controller.
    func openClipboardPage() {
        guard let presenter = presentingController, presenter.presentedViewController == nil else { return }
        let page = YoyoClipboard.makePage(backend: backend, computer: computer)
        page.navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak page] _ in
            page?.dismiss(animated: true)
        })
        presenter.present(UINavigationController(rootViewController: page), animated: true)
    }

    /// Photos… / Files… onto the computer's clipboard (and into its Downloads): picked, read, sent (no paste: pasting
    /// files would copy them wherever the computer's focus is). Only for a backend that sends files.
    func pickForComputer(_ source: ClipboardPicker.Source) {
        guard !clipboardBusy, !clipboardPicker.reading, let presenter = presentingController,
              presenter.presentedViewController == nil, backend.sendsClipboardFiles else { return }
        clipboardPicker.limit = backend.clipboardFileLimit
        let backend = backend
        clipboardPicker.onProgress = { [weak self] text in if let text { self?.notice(.message(text)) } }
        clipboardPicker.onPicked = { [weak self, weak presenter] result in
            guard let self else { return }
            let payload: ClipboardActions.Payload
            switch result {
            case .success(let files):
                do { payload = try ClipboardActions.payload(ClipboardActions.PhoneContent(files: files), limit: backend.clipboardFileLimit) }
                catch { self.notice(.message(error.localizedDescription)); return }
            case .failure(let error):
                self.notice(.message(self.clipboardPicker.message(error)))
                return
            }
            if case .files(let files) = payload { self.notice(.message(self.computer.sendingFiles(files.count))) }
            self.clipboardBusy = true
            Task { [weak self] in
                defer { self?.clipboardBusy = false }
                do {
                    let r = try await ClipboardTransfer.send(payload, backend: backend)
                    guard let self else { return }
                    YoyoClipboardState.of(backend).set(r.status)
                    if let view = presenter?.view { UINotificationFeedbackGenerator(view: view).notificationOccurred(.success) }
                    self.notice(.message(ClipboardTransfer.sentMessage(payload, r, computer: self.computer)))
                } catch {
                    if YoyoHost.current.handleError(error) { return }
                    self?.notice(.message(ClipboardTransfer.failureMessage(error, payload, limit: backend.clipboardFileLimit)))
                }
            }
        }
        clipboardPicker.present(source, from: presenter)
    }

    /// Whether this computer has a clipboard (`YoyoComputer.hasClipboard`: the server's `features`, else the Mac only):
    /// the resource is observed from when it has one; when it stops having one, the keys, the button and the hints go.
    func updateClipboardCapability(_ features: ScreenFeatures?) {
        switch clipboardGate.update(computer.hasClipboard(features)) {
        case .start(let epoch)?:
            let clipboard = YoyoClipboardState.of(backend)
            clipboard.observe(self) { [weak self] state in
                guard let self, self.clipboardGate.isCurrent(epoch) else { return }
                self.clipboardChanged(state.status, supported: ScreenClipboardGate.supported(value: state.status != nil, error: state.error))
            }
            clipboard.refresh()
        case .stop?:
            clipboardChanged(nil, supported: false)
        case nil:
            break
        }
    }

    /// The `clipboard` resource changed: whether the keys show; a new item the computer copied while the session is
    /// active is a hint for the page.
    private func clipboardChanged(_ status: ClipboardStatus?, supported: Bool) {
        hasClipboard = supported
        clipboardStatus = status
        let summary = status?.item?.summary
        var hint: ScreenClipboardHint?
        if status != nil {
            if isActive { hint = ScreenClipboardHint.onMacChange(summary, previous: macCountKnown) }
            macCountKnown = summary?.changeCount ?? -1
            clipboardMarks.knowMac(summary)
        }
        onClipboardChange?(hint)
        changed(.clipboard)
    }
}
