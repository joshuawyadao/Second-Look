import Foundation

/// Keeps an explicit sign-out separate from whether secure storage can delete its old record.
/// The scope includes the app/test namespace and public backend identity, never a credential.
public struct SessionRestorationBarrier {
    private let preferences: UserDefaults
    private let key: String

    public init(scope: String, preferences: UserDefaults = .standard) {
        self.preferences = preferences
        key = "secondlook.session.signed-out.v1." + scope
    }

    public func deleteCredentials(_ delete: () throws -> Void) throws {
        // Record the user's intent before secure storage is touched. A leftover item must
        // not become a session again after a failed deletion or a process restart.
        preferences.set(true, forKey: key)
        try delete()
    }

    public func persistCredentials(_ save: () throws -> Void) throws {
        try save()
        preferences.removeObject(forKey: key)
    }

    public func restoreCredentials<Value>(read: () throws -> Value?,
                                          delete: () throws -> Void) throws -> Value? {
        if preferences.bool(forKey: key) {
            // Retry only deletion; never decode or authenticate the old saved record.
            try delete()
            return nil
        }
        return try read()
    }
}
