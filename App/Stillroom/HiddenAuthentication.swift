import LocalAuthentication

enum HiddenAuthentication {
    /// Touch ID when the Mac has it, otherwise the account password.
    static func unlock() async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return false
        }
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock the Hidden album") { success, _ in
                continuation.resume(returning: success)
            }
        }
    }
}
