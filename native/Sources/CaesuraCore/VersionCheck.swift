import Foundation

/// Fetches the latest Caesura release tag from the GitHub API.
public enum VersionCheck {
    public static func fetchLatestTag(completion: @escaping (String?) -> Void) {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/dingjee/caesura/releases/latest")!)
        request.httpMethod = "GET"
        request.setValue("dingjee/caesura", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        URLSession.shared.dataTask(with: request) { data, _, error in
            guard error == nil, let data,
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let tag = object["tag_name"] as? String else {
                Log.info("Caesura: could not check for new version")
                DispatchQueue.main.async { completion(nil) }
                return
            }
            DispatchQueue.main.async { completion(tag) }
        }.resume()
    }

    /// Full legacy gate: local version, notify flag, silent flag.
    public static func isNewVersionAvailable(remoteTag: String?, localVersion: String) -> Bool {
        guard let remoteTag else { return false }
        return Utils.isNewerVersion(candidate: remoteTag, current: localVersion)
    }
}
