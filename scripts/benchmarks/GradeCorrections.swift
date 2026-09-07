import Foundation

@main
struct GradeCorrections {
    struct Input: Decodable {
        let original: String
        let candidate: String
        let terms: [String]
    }

    static func main() throws {
        while let line = readLine() {
            let input = try JSONDecoder().decode(Input.self, from: Data(line.utf8))
            let reason = TextCorrectionPolicy.rejectionReason(
                original: input.original, candidate: input.candidate, preferredTerms: input.terms
            )
            let value: [String: Any] = ["accepted": reason == nil, "rejectionReason": reason as Any? ?? NSNull()]
            let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        }
    }
}
