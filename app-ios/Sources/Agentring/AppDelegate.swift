import UIKit
import PushKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, @preconcurrency PKPushRegistryDelegate, UNUserNotificationCenterDelegate {
    private var registry: PKPushRegistry?
    private let model = AppModel.shared

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        _ = model.calls
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let reply = UNTextInputNotificationAction(identifier: "REPLY", title: "Reply", options: [.authenticationRequired],
            textInputButtonTitle: "Send", textInputPlaceholder: "Message your agent")
        center.setNotificationCategories([UNNotificationCategory(identifier: "MESSAGE", actions: [reply], intentIdentifiers: [])])
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        self.registry = registry
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
        model.apnsToken = token.map { String(format: "%02x", $0) }.joined()
        Task { await model.registerTokens() }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        model.pushRegistration = "Apple push unavailable"
    }

    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        model.voipToken = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        Task { await model.registerTokens() }
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        guard type == .voIP else { return }
        model.voipToken = nil
        Task { await model.registerTokens(clearVoip: true) }
    }

    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload,
                      for type: PKPushType, completion: @escaping () -> Void) {
        guard let credentials = model.credentials,
              let event = PushVerifier.verify(payload.dictionaryPayload, credentials: credentials),
              event.type == "call.invite", event.direction == "agent_to_user", event.callId != nil else {
            model.calls.rejectPush(completion: completion); return
        }
        model.calls.incomingCall(event, completion: completion)
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        guard let credentials = model.credentials, let event = PushVerifier.verify(userInfo, credentials: credentials) else {
            completionHandler(.noData); return
        }
        Task {
            do { try await model.receive(event); completionHandler(.newData) }
            catch { model.present(error); completionHandler(.failed) }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        Task { @MainActor in
            guard let credentials = model.credentials,
                  let event = PushVerifier.verify(notification.request.content.userInfo, credentials: credentials) else {
                completionHandler([]); return
            }
            completionHandler([.banner, .sound])
            do { try await model.receive(event) } catch { model.present(error) }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            guard let credentials = model.credentials,
                  let event = PushVerifier.verify(response.notification.request.content.userInfo, credentials: credentials) else {
                completionHandler(); return
            }
            defer { completionHandler() }
            if let reply = response as? UNTextInputNotificationResponse {
                do { try await model.send(reply.userText, replyTo: event.msgId) }
                catch { model.present(error) }
            } else {
                do { try await model.receive(event); await model.refresh() }
                catch { model.present(error) }
            }
        }
    }
}
