import DailyPlannerDomain
import Foundation

public enum GoogleRequestBuilder {
    public static func get(url: URL, accessToken: GoogleAccessToken) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let authorization = accessToken.withUnsafeRawValue { "Bearer \($0)" }
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        try GoogleNetworkPolicy.validate(request)
        return request
    }

    /// A JSON POST to one of the two write endpoints.
    ///
    /// It sets exactly two headers, because `GoogleNetworkPolicy` permits exactly two on a
    /// write and refuses the request otherwise. That is not a coincidence to be tidied away
    /// later: the policy is the list of what this app may do to someone's account, and every
    /// request it lets through is one that was written to match it deliberately.
    public static func postJSON(
        url: URL,
        accessToken: GoogleAccessToken,
        body: Data
    ) throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let authorization = accessToken.withUnsafeRawValue { "Bearer \($0)" }
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        try GoogleNetworkPolicy.validate(request)
        return request
    }
}
