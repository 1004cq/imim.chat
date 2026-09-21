import Foundation

extension APIClient {
    func logout(authTokenOverride: String? = nil) async throws {
        let _: EmptyResponse = try await request(
            "/auth/logout",
            method: "POST",
            authTokenOverride: authTokenOverride
        )
    }
}
