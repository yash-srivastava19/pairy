package pairy

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class PairyClientTest {

    @Test
    fun `request body contains question and system prompt`() {
        val body = PairyClient.buildRequestBody("is this O(n)?", "```python\ncode\n```", 8192)
        assertTrue(body.contains("is this O(n)?"))
        assertTrue(body.contains("senior pair programmer"))
        assertTrue(body.contains("\"maxOutputTokens\":8192"))
    }

    @Test
    fun `parses successful response`() {
        val responseBody = """{"candidates":[{"content":{"parts":[{"text":"Use a dict."}],"role":"model"}}]}"""
        val result = PairyClient.parseResponse(responseBody)
        assertTrue(result is PairyResult.Success)
        assertEquals("Use a dict.", (result as PairyResult.Success).text)
    }

    @Test
    fun `parses api error response`() {
        val responseBody = """{"error":{"message":"invalid API key","status":"UNAUTHENTICATED"}}"""
        val result = PairyClient.parseResponse(responseBody)
        assertTrue(result is PairyResult.Failure)
        assertEquals("invalid API key", (result as PairyResult.Failure).message)
    }

    @Test
    fun `treats malformed json as failure`() {
        val result = PairyClient.parseResponse("{not valid json")
        assertTrue(result is PairyResult.Failure)
    }

    @Test
    fun `treats empty candidates as failure`() {
        val result = PairyClient.parseResponse("""{"candidates":[]}""")
        assertTrue(result is PairyResult.Failure)
        assertEquals("Empty response from API", (result as PairyResult.Failure).message)
    }
}
