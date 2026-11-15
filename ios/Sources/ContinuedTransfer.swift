import Foundation
import BackgroundTasks
import UIKit

@MainActor
protocol TransferBackgroundProviding: AnyObject {
    var canContinue: Bool { get }
    func begin(total: Int64, completed: Int64, sending: Bool, expire: @escaping () -> Void, state: @escaping (String) -> Void)
    func update(completed: Int64, total: Int64)
    func finish(success: Bool)
}

/// iOS owns both execution permission and its Live Activity. No push server,
/// fake audio, timer keepalive or unrestricted background entitlement is used.
@MainActor
final class ContinuedTransfer: TransferBackgroundProviding {
    private var nativeTask: AnyObject?
    private var identifier: String?
    private var marker: UUID?
    private var expired = false
    private var total: Int64 = 1
    private var completed: Int64 = 0
    private var sending = false
    var canContinue: Bool { nativeTask != nil && !expired }

    func begin(total: Int64, completed: Int64, sending: Bool, expire: @escaping () -> Void, state: @escaping (String) -> Void) {
        finish(success:false)
        self.total=max(0,total)+1; self.completed=max(0,completed); self.sending=sending; expired=false
        let fallback = sending ? "Keep Nearby open until Android confirms the save." : "Keep Nearby open. Leaving the app pauses this download."
        guard #available(iOS 26.0, *) else { state(fallback); return }
        #if targetEnvironment(simulator)
        state(fallback) // This API's scheduling/UI require a real device.
        return
        #else
        guard UIApplication.shared.applicationState == .active, let bundle=Bundle.main.bundleIdentifier else { state(fallback); return }
        let id=bundle+".transfer."+UUID().uuidString
        // A free-account re-signer can suffix the bundle ID. The broad app-local
        // prefix in Info.plist also covers that suffix. Fail safely if rewritten otherwise.
        let permitted=Bundle.main.object(forInfoDictionaryKey:"BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
        guard permitted.contains(where: { $0 == id || ($0.hasSuffix(".*") && id.hasPrefix(String($0.dropLast()))) }) else {
            state("Background progress is unavailable in this installation. "+fallback); return
        }
        let current=UUID(); marker=current; identifier=id
        let registered=BGTaskScheduler.shared.register(forTaskWithIdentifier:id,using:.main) { [weak self] task in
            // Continued-processing registration is allowed after launch. Each
            // identifier is registered once; weak capture cannot retain old transfers.
            MainActor.assumeIsolated {
                guard let self, self.marker==current, let continued=task as? BGContinuedProcessingTask else {
                    task.setTaskCompleted(success:false); return
                }
                self.nativeTask=continued
                continued.progress.totalUnitCount=self.total
                continued.progress.completedUnitCount=min(self.completed,self.total-1)
                continued.expirationHandler = { [weak self] in
                    Task { @MainActor in
                        guard let self, self.marker==current else { return }
                        self.expired=true
                        state("Background transfer stopped. Saved download pieces are kept; return to Nearby to resume.")
                        expire()
                    }
                }
                state("Background transfer enabled. Follow progress on your Lock Screen or Dynamic Island.")
            }
        }
        guard registered else { marker=nil; identifier=nil; state(fallback); return }
        let request=BGContinuedProcessingTaskRequest(identifier:id,title:"Nearby transfer",subtitle:sending ? "Preparing to send" : "Receiving securely")
        request.strategy = .fail // Never leave an authorized transfer queued for later.
        do { try BGTaskScheduler.shared.submit(request); state("Requesting background transfer… Keep Nearby open until enabled.") }
        catch { finish(success:false); state("Background transfer is unavailable right now. "+fallback) }
        #endif
    }
    func update(completed: Int64, total: Int64) {
        self.total=max(0,total)+1; self.completed=max(0,min(completed,max(0,total)))
        if #available(iOS 26.0,*), let task=nativeTask as? BGContinuedProcessingTask, !expired {
            task.progress.totalUnitCount=self.total
            task.progress.completedUnitCount=self.completed
            let percent=total>0 ? Int(Double(self.completed)/Double(total)*100) : 0
            task.updateTitle("Nearby transfer",subtitle:completed>=total ? "Verifying the saved file…" : "\(sending ? "Sending" : "Receiving") \(percent)%")
        }
    }
    func finish(success: Bool) {
        let wasExpired=expired
        marker=nil
        if #available(iOS 26.0,*) {
            if let task=nativeTask as? BGContinuedProcessingTask {
                if success && !wasExpired { task.progress.completedUnitCount=task.progress.totalUnitCount }
                task.setTaskCompleted(success:success && !wasExpired)
            }
            if let identifier { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier:identifier) }
        }
        nativeTask=nil; identifier=nil; expired=false
    }
}
