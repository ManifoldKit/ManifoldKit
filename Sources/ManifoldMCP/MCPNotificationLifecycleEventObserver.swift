import Foundation

#if canImport(UIKit)
import UIKit
#endif

public final class MCPNotificationLifecycleEventObserver: MCPLifecycleEventObserver, @unchecked Sendable {
    public let events: AsyncStream<MCPLifecycleEvent>

    private let notificationCenter: NotificationCenter
    private let continuation: AsyncStream<MCPLifecycleEvent>.Continuation
    private var tokens: [NSObjectProtocol] = []

    public init(
        notificationCenter: NotificationCenter = .default,
        mapping: [Notification.Name: MCPLifecycleEvent]
    ) {
        self.notificationCenter = notificationCenter

        let (events, continuation) = AsyncStream.makeStream(of: MCPLifecycleEvent.self)
        self.events = events
        self.continuation = continuation

        self.tokens = mapping.map { name, event in
            notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: nil
            ) { _ in
                continuation.yield(event)
            }
        }
    }

    deinit {
        for token in tokens {
            notificationCenter.removeObserver(token)
        }
        continuation.finish()
    }

    public static func platformMemoryWarnings(
        notificationCenter: NotificationCenter = .default
    ) -> MCPNotificationLifecycleEventObserver? {
        #if canImport(UIKit)
        return MCPNotificationLifecycleEventObserver(
            notificationCenter: notificationCenter,
            mapping: [UIApplication.didReceiveMemoryWarningNotification: .memoryWarning]
        )
        #else
        _ = notificationCenter
        return nil
        #endif
    }
}
