//
//  Stats.swift
//  AutoSwitcher
//
//  Tiny correction counter shown in the menu: "corrected today / total".
//  Persisted in UserDefaults; the daily counter rolls over by comparing a
//  stored yyyy-MM-dd stamp on every mutation and on init.
//

import Foundation
import Combine

final class StatsStore: ObservableObject {

    static let shared = StatsStore()

    @Published private(set) var today: Int = 0
    @Published private(set) var total: Int = 0

    private let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private init() {
        rollOverIfNeeded()
        today = UserDefaults.standard.integer(forKey: AppSettings.Keys.statsToday)
        total = UserDefaults.standard.integer(forKey: AppSettings.Keys.statsTotal)
    }

    /// Thread-safe: hops to main (all @Published mutations must be there).
    func recordCorrection() {
        onMain {
            self.rollOverIfNeeded()
            self.today += 1
            self.total += 1
            self.persist()
        }
    }

    /// A revert means the correction was unwanted — take it back out of the
    /// counters so the numbers reflect useful corrections.
    func recordRevert() {
        onMain {
            self.rollOverIfNeeded()
            self.today = max(0, self.today - 1)
            self.total = max(0, self.total - 1)
            self.persist()
        }
    }

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }

    private func rollOverIfNeeded() {
        let todayStamp = dayFormatter.string(from: Date())
        let stored = UserDefaults.standard.string(forKey: AppSettings.Keys.statsDay)
        if stored != todayStamp {
            UserDefaults.standard.set(todayStamp, forKey: AppSettings.Keys.statsDay)
            UserDefaults.standard.set(0, forKey: AppSettings.Keys.statsToday)
            today = 0
        }
    }

    private func persist() {
        UserDefaults.standard.set(today, forKey: AppSettings.Keys.statsToday)
        UserDefaults.standard.set(total, forKey: AppSettings.Keys.statsTotal)
    }
}
