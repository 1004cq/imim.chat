import Foundation

@main private enum FriendLinkRegression {
    static func main() {
        var checks = 0
        func check(_ ok: Bool, _ name: String) {
            precondition(ok, name)
            checks += 1
            print("PASS: \(name)")
        }
        for id in ["0", "1", "test1", "peer-123", "peer_456", "u.7", "000", String(repeating: "a", count: 128)] {
            check(FriendLink.validUserID(id) == id, "valid ID accepted")
            let scheme = FriendLink.schemeURL(userID: id)!
            check(FriendLink.userID(from: scheme) == id, "custom scheme round trip")
            check(FriendLink.shareURL(userID: id)?.absoluteString == "https://app.imim.chat/user/\(id)",
                  "share URL uses verified App domain")
            check(FriendLink.userID(from: URL(string: "https://app.imim.chat/user/\(id)")!) == id,
                  "HTTPS round trip including short IDs")
        }
        for value in ["", ".", "..", "a/b", "a?b", "a#b", "a%2Fb", "a\\b", "a b", "\n", String(repeating: "a", count: 129)] {
            check(FriendLink.validUserID(value) == nil && FriendLink.schemeURL(userID: value) == nil,
                  "unsafe identifier rejected")
        }
        for link in ["imim://user/", "imim://user/0/", "imim://user/0/1", "imim://user/0?admin=1",
                     "imim://user/0#fragment", "imim://user:9/0", "imim://owner@user/0",
                     "imim://owner:password@user/0", "imim://user/%2F0", "imim://user/%252F0",
                     "imim://user/%2e%2e", "imim://user/%00", "https://app.imim.chat/user/0?redirect=evil",
                     "http://app.imim.chat/user/0", "https://wed.imim.chat/user/0",
                     "https://app.imim.chat.evil.invalid/user/0", "https://evil.invalid/user/0",
                     "https://app.imim.chat:443/user/0", "https://owner@app.imim.chat/user/0",
                     "https://app.imim.chat/user/0/../1", "imim://proxy?server=one.invalid&port=1080",
                     "tg://socks?server=one.invalid&port=1080"] {
            check(FriendLink.userID(from: URL(string: link)!) == nil, "malformed or unrelated URL rejected")
        }
        check(FriendLink.userID(from: URL(string: "IMIM://USER/0")!) == "0", "scheme and host case normalize")
        check(FriendLink.userID(from: URL(string: "imim://user/%30")!) == "0", "single percent decode")
        print("FRIEND LINK REGRESSION: \(checks) checks passed")
    }
}
