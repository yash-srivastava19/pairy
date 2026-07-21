package pairy

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.nio.file.Files
import java.nio.file.Path

@Serializable
data class PairyConfigData(
    @SerialName("api_key") val apiKey: String = "",
    val model: String = "gemini-2.5-flash",
    @SerialName("context_lines") val contextLines: Int = 20,
    @SerialName("max_tokens") val maxTokens: Int = 8192
)

object PairyConfig {
    private val json = Json { ignoreUnknownKeys = true }

    fun configPath(): Path =
        Path.of(System.getProperty("user.home"), ".config", "pairy", "config.json")

    fun parseConfig(jsonText: String): PairyConfigData =
        json.decodeFromString(PairyConfigData.serializer(), jsonText)

    fun load(): PairyConfigData {
        val path = configPath()
        if (!Files.exists(path)) return PairyConfigData()
        return try {
            parseConfig(Files.readString(path))
        } catch (e: Exception) {
            PairyConfigData()
        }
    }
}
