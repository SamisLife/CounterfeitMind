import Foundation
import UIKit

final class GeminiClient {

    private let apiKey: String
    private let model = "gemini-2.5-flash-lite"

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    func extractBanknoteFields(image: UIImage) async throws -> String {
        let data = image.jpegData(compressionQuality: 0.85)!
        let b64 = data.base64EncodedString()

        let prompt = """
You are a professional banker. You dedicated one third of your life studying currencies from all over the world, denominations, and you developed a very critical and weird skill which is to retrieve serial numbers from any currency in the world in milliseconds. You also pair with it some metrics such as currency types (USD, EUR...), and which denomination. You start reciting them in this format:
{
 "currency": "USD",
 "denomination": 10,
 "serial": "A1B2C3D4"
}
Please follow the exact format cited, and return null for each value if none exist.
"""

        let body: [String: Any] = [
            "contents": [[
                "parts": [
                    ["text": prompt],
                    ["inline_data": [
                        "mime_type": "image/jpeg",
                        "data": b64
                    ]]
                ]
            ]]
        ]

        let url = URL(string:
            "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent?key=\(apiKey)"
        )!

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (dataResp, _) = try await URLSession.shared.data(for: req)
        let json = try JSONSerialization.jsonObject(with: dataResp) as! [String: Any]

        let text = (((json["candidates"] as? [[String: Any]])?.first?["content"]
                    as? [String: Any])?["parts"] as? [[String: Any]])?.first?["text"] as? String

        return text ?? "{}"
    }
}
