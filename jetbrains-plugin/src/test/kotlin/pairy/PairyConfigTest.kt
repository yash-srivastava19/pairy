package pairy

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertThrows
import org.junit.jupiter.api.Test

class PairyConfigTest {

    @Test
    fun `parses full config`() {
        val json = """{"api_key":"abc123","model":"gemini-2.0-flash","context_lines":10,"max_tokens":4096}"""
        val cfg = PairyConfig.parseConfig(json)
        assertEquals("abc123", cfg.apiKey)
        assertEquals("gemini-2.0-flash", cfg.model)
        assertEquals(10, cfg.contextLines)
        assertEquals(4096, cfg.maxTokens)
    }

    @Test
    fun `applies defaults for missing fields`() {
        val cfg = PairyConfig.parseConfig("""{"api_key":"abc123"}""")
        assertEquals("abc123", cfg.apiKey)
        assertEquals("gemini-2.5-flash", cfg.model)
        assertEquals(20, cfg.contextLines)
        assertEquals(8192, cfg.maxTokens)
    }

    @Test
    fun `ignores unknown fields`() {
        val json = """{"api_key":"abc123","sessions_dir":"~/.local/share/pairy/sessions"}"""
        val cfg = PairyConfig.parseConfig(json)
        assertEquals("abc123", cfg.apiKey)
    }

    @Test
    fun `throws on malformed json`() {
        assertThrows(Exception::class.java) {
            PairyConfig.parseConfig("{not valid json")
        }
    }
}
