import Foundation
import Combine

/// User choices that gate what the app is allowed to read and show.
///
/// The important one is `hasCompletedSetup`. Until it's true the app reads *only*
/// the account config files — enough to list the accounts it found and ask about
/// them — and never touches the transcripts. Reading someone's conversation files
/// before they've agreed to it is the wrong default, even when they're that
/// person's own files on their own machine.
@MainActor
final class AppPreferences: ObservableObject {
    static let shared = AppPreferences()

    private enum Key {
        static let completedSetup = "hasCompletedSetup"
        static let enabledAccounts = "enabledAccountIDs"
        static let hideEmails = "hideEmails"
    }

    @Published var hasCompletedSetup: Bool {
        didSet { defaults.set(hasCompletedSetup, forKey: Key.completedSetup) }
    }

    /// Accounts the user chose to include. Empty means none — not "all" — so an
    /// explicit deselection is never silently overridden.
    @Published var enabledAccountIDs: Set<String> {
        didSet { defaults.set(Array(enabledAccountIDs), forKey: Key.enabledAccounts) }
    }

    /// Replaces addresses with the account label everywhere, including the snapshot
    /// the widget reads. Useful when screen-sharing or posting screenshots.
    @Published var hideEmails: Bool {
        didSet { defaults.set(hideEmails, forKey: Key.hideEmails) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hasCompletedSetup = defaults.bool(forKey: Key.completedSetup)
        enabledAccountIDs = Set(defaults.stringArray(forKey: Key.enabledAccounts) ?? [])
        hideEmails = defaults.bool(forKey: Key.hideEmails)
    }

    /// True once the user has actually been through the picker. Distinguishes
    /// "hasn't chosen yet" from "chose to include nothing", so re-opening setup
    /// after deselecting everything doesn't silently re-tick the boxes.
    private var hasChosenAccounts: Bool {
        get { defaults.bool(forKey: "hasChosenAccounts") }
        set { defaults.set(newValue, forKey: "hasChosenAccounts") }
    }

    /// Ticks every discovered account the first time the picker is shown, so the
    /// common case is one click. They're all visible and un-tickable — the point is
    /// that the choice is presented, not that it starts empty.
    func primeSelection(with ids: [String]) {
        guard !hasChosenAccounts else { return }
        enabledAccountIDs = Set(ids)
    }

    func confirmSetup() {
        hasChosenAccounts = true
        hasCompletedSetup = true
    }

    func isEnabled(_ id: String) -> Bool { enabledAccountIDs.contains(id) }

    func setEnabled(_ enabled: Bool, for id: String) {
        if enabled { enabledAccountIDs.insert(id) } else { enabledAccountIDs.remove(id) }
    }

    /// Re-opens the first-run screen without discarding the existing choices.
    func reopenSetup() { hasCompletedSetup = false }
}
