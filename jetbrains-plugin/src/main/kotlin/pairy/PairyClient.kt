package pairy

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.net.URI
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import java.time.Duration
import java.util.concurrent.CompletableFuture

const val PAIRY_SYSTEM_PROMPT = """You are a senior pair programmer. The user has left a `pair:` comment with a question or thought. Your job is not just to answer — it is to help them think more clearly and write better code.

How to respond:
- If the question reveals an unstated assumption or a gap in thinking, surface it first. Example: "Before deciding, what's the expected range of X?" or "Your question assumes Y is always non-nil — is that guaranteed by the caller?"
- If the surrounding code has a problem unrelated to the question, mention it briefly at the end.
- Give a direct opinion when asked. Do not hedge unless the tradeoff genuinely depends on context you don't have — and if so, say which specific factor is the deciding one.
- If they are on the right track, confirm it in one clause and push to the next consideration.
- If they are off track, say so directly and redirect. Do not soften it.
- Ask one probing question back when it would help them reason through the problem. Do not ask questions just to seem thorough.

Constraints:
- 2-5 sentences. Every word earns its place.
- No markdown headers. No bullet lists unless genuinely enumerating distinct things.
- No "great question", no preamble, no summary at the end.
- Write as if your response will appear as comment lines in the file — plain prose, ~80 chars per line.
- Always reference the actual code: use the variable names, function names, and patterns visible in the context."""

@Serializable
data class GeminiPart(val text: String)

@Serializable
data class GeminiContent(val role: String? = null, val parts: List<GeminiPart>)

@Serializable
data class GeminiSystemInstruction(val parts: List<GeminiPart>)

@Serializable
data class GeminiGenerationConfig(val maxOutputTokens: Int)

@Serializable
data class GeminiRequest(
    @SerialName("system_instruction") val systemInstruction: GeminiSystemInstruction,
    val contents: List<GeminiContent>,
    val generationConfig: GeminiGenerationConfig
)

@Serializable
data class GeminiError(val message: String? = null, val status: String? = null)

@Serializable
data class GeminiCandidate(val content: GeminiContent)

@Serializable
data class GeminiResponse(
    val candidates: List<GeminiCandidate>? = null,
    val error: GeminiError? = null
)

sealed class PairyResult {
    data class Success(val text: String) : PairyResult()
    data class Failure(val message: String) : PairyResult()
}

object PairyClient {
    private val json = Json { ignoreUnknownKeys = true }
    private val httpClient: HttpClient = HttpClient.newBuilder()
        .connectTimeout(Duration.ofSeconds(30))
        .build()

    fun buildUrl(model: String, apiKey: String): String =
        "https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$apiKey"

    fun buildRequestBody(question: String, context: String, maxTokens: Int): String {
        val userContent = "$context\n\nQuestion: $question"
        val request = GeminiRequest(
            systemInstruction = GeminiSystemInstruction(listOf(GeminiPart(PAIRY_SYSTEM_PROMPT))),
            contents = listOf(GeminiContent(role = "user", parts = listOf(GeminiPart(userContent)))),
            generationConfig = GeminiGenerationConfig(maxTokens)
        )
        return json.encodeToString(GeminiRequest.serializer(), request)
    }

    fun parseResponse(responseBody: String): PairyResult {
        val decoded = try {
            json.decodeFromString(GeminiResponse.serializer(), responseBody)
        } catch (e: Exception) {
            return PairyResult.Failure("Malformed response from API")
        }
        decoded.error?.let {
            return PairyResult.Failure(it.message ?: "API error: ${it.status ?: "unknown"}")
        }
        val text = decoded.candidates?.firstOrNull()?.content?.parts?.firstOrNull()?.text
        return if (text.isNullOrEmpty()) PairyResult.Failure("Empty response from API") else PairyResult.Success(text)
    }

    fun sendAsync(
        question: String,
        context: String,
        model: String,
        apiKey: String,
        maxTokens: Int
    ): CompletableFuture<PairyResult> {
        val body = buildRequestBody(question, context, maxTokens)
        val request = HttpRequest.newBuilder()
            .uri(URI.create(buildUrl(model, apiKey)))
            .header("content-type", "application/json")
            .POST(HttpRequest.BodyPublishers.ofString(body))
            .build()

        return httpClient.sendAsync(request, HttpResponse.BodyHandlers.ofString())
            .thenApply { response -> parseResponse(response.body()) }
            .exceptionally { throwable -> PairyResult.Failure("Network error: ${throwable.message}") }
    }
}
