# Pairy for JetBrains (PyCharm) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port Pairy's core loop (write a `pair:` comment, trigger it, get an AI response as inline text that's never written to the file) to a Kotlin/Gradle IntelliJ Platform plugin, installed locally into PyCharm for personal use only.

**Architecture:** A standalone Gradle project at `jetbrains-plugin/` inside this repo, built against the user's real local PyCharm install as the platform dependency. Five focused Kotlin objects mirror the existing `lua/pairy/*.lua` module split (config, detector, client, renderer, actions/dispatch), each with pure, unit-testable core functions and thin platform-dependent adapters around them.

**Tech Stack:** Kotlin, Gradle (IntelliJ Platform Gradle Plugin 2.x), kotlinx.serialization for JSON, `java.net.http.HttpClient` for the Gemini API call, JUnit 5 for unit tests.

## Global Constraints

- Personal, local-install use only — no JetBrains Marketplace, no plugin signing.
- Reuse the existing config file verbatim: `~/.config/pairy/config.json` (keys: `api_key`, `model` default `gemini-2.5-flash`, `context_lines` default 20, `max_tokens` default 8192). Do not introduce a second config file or re-prompt for the API key.
- v1 scope is the core loop only: Send, Retry, Send All, Clear, Clear All, Cancel, and selection-based questions. No conversation threading, no `PAIRY.md` project context, no session saving, no hover inspect, no yank/toggle.
- v1 is non-streaming: one blocking Gemini `generateContent` call per request, not SSE streaming.
- Responses render as read-only `Inlay` block elements under the `pair:` line — the `Document`/file content must never be modified by any Pairy code path.
- Local platform dependency path: `/home/yashs/pycharm-2026.1.4` (confirmed real install; do not use a versioned Marketplace platform artifact).
- Only JDK available system-wide is JDK 26 (`java -version` → `openjdk 26.0.1`) — Task 1 must verify Gradle actually runs on it before proceeding, since Gradle's JDK support can lag new JDK releases.
- Design spec: `docs/superpowers/specs/2026-07-21-jetbrains-plugin-design.md` — consult it for the "why" behind any decision below.

---

### Task 1: Gradle project scaffold

**Files:**
- Create: `jetbrains-plugin/settings.gradle.kts`
- Create: `jetbrains-plugin/build.gradle.kts`
- Create: `jetbrains-plugin/gradle.properties`
- Create: `jetbrains-plugin/.gitignore`
- Create: `jetbrains-plugin/src/main/resources/META-INF/plugin.xml`
- Create (generated): `jetbrains-plugin/gradlew`, `jetbrains-plugin/gradlew.bat`, `jetbrains-plugin/gradle/wrapper/*`

**Interfaces:**
- Consumes: nothing (first task)
- Produces: a Gradle project buildable via `./gradlew build`, with the local PyCharm install wired as the platform dependency, JUnit 5 wired for tests, and kotlinx.serialization available — everything later tasks build on top of.

- [ ] **Step 1: Confirm Gradle is available, install if not**

Run: `gradle --version`

If that fails with "command not found": Gradle isn't installed system-wide. Install it — this needs your sudo password, so run it yourself if you're not already root-equivalent:

```bash
sudo pacman -S gradle
```

- [ ] **Step 2: Create the project directory and generate the Gradle wrapper**

```bash
mkdir -p ~/Desktop/Programming/2026_Q1_Projects/pairy/jetbrains-plugin
cd ~/Desktop/Programming/2026_Q1_Projects/pairy/jetbrains-plugin
gradle wrapper
```

Using `gradle wrapper` with no explicit `--gradle-version` pins the wrapper to whatever Gradle version you just installed — guaranteed compatible with your system's only JDK (26), rather than risking a hardcoded older version that predates JDK 26 support.

- [ ] **Step 3: Verify the wrapper actually runs on JDK 26**

Run: `./gradlew --version`

Expected: version info block printing Gradle, Kotlin, and JVM versions, no error.

If this fails with a JDK-incompatibility error (e.g. "Unsupported class file major version" or similar): your installed Gradle version doesn't yet support JDK 26. Fix by installing an older LTS JDK alongside it and pointing the wrapper at it:

```bash
sudo pacman -S jdk21-openjdk
echo "org.gradle.java.home=/usr/lib/jvm/java-21-openjdk" >> gradle.properties
./gradlew --version
```

Do not proceed past this step until `./gradlew --version` succeeds cleanly.

- [ ] **Step 4: Write `settings.gradle.kts`**

```kotlin
rootProject.name = "pairy-jetbrains"

plugins {
    id("org.gradle.toolchains.foojay-resolver-convention") version "0.8.0"
}
```

The foojay resolver lets Gradle auto-provision a JDK 21 toolchain for *compiling* the plugin, independent of whichever JDK is running Gradle itself (set in Step 3).

- [ ] **Step 5: Write `build.gradle.kts`**

```kotlin
plugins {
    kotlin("jvm") version "1.9.24"
    kotlin("plugin.serialization") version "1.9.24"
    id("org.jetbrains.intellij.platform") version "2.1.0"
}

group = "dev.yashsrivastava19"
version = "0.1.0"

repositories {
    mavenCentral()
    intellijPlatform {
        defaultRepositories()
    }
}

dependencies {
    intellijPlatform {
        local("/home/yashs/pycharm-2026.1.4")
        instrumentationTools()
    }
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.6.3")
    testImplementation("org.junit.jupiter:junit-jupiter:5.10.2")
    testRuntimeOnly("org.junit.jupiter:junit-jupiter-engine:5.10.2")
}

kotlin {
    jvmToolchain(21)
}

tasks {
    test {
        useJUnitPlatform()
    }
}

intellijPlatform {
    pluginConfiguration {
        ideaVersion {
            sinceBuild.set("241")
            untilBuild.set(provider { null })
        }
    }
}
```

If `./gradlew build` (Step 8) fails to resolve `org.jetbrains.intellij.platform` version `2.1.0`, check https://plugins.gradle.org/plugin/org.jetbrains.intellij.platform for the current version and update the string above.

- [ ] **Step 6: Write `gradle.properties`**

```properties
org.gradle.jvmargs=-Xmx2g
kotlin.stdlib.default.dependency=false
```

(If Step 3 required the `org.gradle.java.home` fallback line, keep it here too — this file was created in Step 3.)

- [ ] **Step 7: Write `.gitignore` and the minimal `plugin.xml`**

`jetbrains-plugin/.gitignore`:

```
.gradle/
build/
out/
```

`jetbrains-plugin/src/main/resources/META-INF/plugin.xml`:

```xml
<idea-plugin>
    <id>dev.yashsrivastava19.pairy</id>
    <name>Pairy</name>
    <vendor>yash-srivastava19</vendor>
    <description>AI pair programming inside the editor. Write a pair: comment, get a response as inline text, never written to the file.</description>

    <depends>com.intellij.modules.platform</depends>
</idea-plugin>
```

- [ ] **Step 8: Build and verify**

Run: `./gradlew build`

Expected: `BUILD SUCCESSFUL`. This confirms the local platform dependency resolves, Kotlin compiles, and the (currently empty) test suite runs.

- [ ] **Step 9: Commit**

```bash
cd ~/Desktop/Programming/2026_Q1_Projects/pairy
git add jetbrains-plugin/settings.gradle.kts jetbrains-plugin/build.gradle.kts \
        jetbrains-plugin/gradle.properties jetbrains-plugin/.gitignore \
        jetbrains-plugin/src/main/resources/META-INF/plugin.xml \
        jetbrains-plugin/gradlew jetbrains-plugin/gradlew.bat jetbrains-plugin/gradle/
git commit -m "feat(jetbrains): scaffold Gradle plugin project"
```

---

### Task 2: PairyConfig — read the existing `~/.config/pairy/config.json`

**Files:**
- Create: `jetbrains-plugin/src/main/kotlin/pairy/PairyConfig.kt`
- Test: `jetbrains-plugin/src/test/kotlin/pairy/PairyConfigTest.kt`

**Interfaces:**
- Consumes: nothing
- Produces: `data class PairyConfigData(val apiKey: String, val model: String, val contextLines: Int, val maxTokens: Int)`, `PairyConfig.parseConfig(jsonText: String): PairyConfigData`, `PairyConfig.load(): PairyConfigData` — used by Task 6's actions.

- [ ] **Step 1: Write the failing test**

`jetbrains-plugin/src/test/kotlin/pairy/PairyConfigTest.kt`:

```kotlin
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./gradlew test --tests "pairy.PairyConfigTest"`
Expected: FAIL — `PairyConfig` is unresolved.

- [ ] **Step 3: Write `PairyConfig.kt`**

```kotlin
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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `./gradlew test --tests "pairy.PairyConfigTest"`
Expected: PASS, 4 tests.

- [ ] **Step 5: Commit**

```bash
cd ~/Desktop/Programming/2026_Q1_Projects/pairy
git add jetbrains-plugin/src/main/kotlin/pairy/PairyConfig.kt jetbrains-plugin/src/test/kotlin/pairy/PairyConfigTest.kt
git commit -m "feat(jetbrains): read ~/.config/pairy/config.json"
```

---

### Task 3: PairyDetector — find and format `pair:` comments

**Files:**
- Create: `jetbrains-plugin/src/main/kotlin/pairy/PairyDetector.kt`
- Test: `jetbrains-plugin/src/test/kotlin/pairy/PairyDetectorTest.kt`

**Interfaces:**
- Consumes: nothing
- Produces: `data class PairyDetector.PairComment(val lineIndex: Int, val lineText: String, val question: String, val context: String)`, `PairyDetector.extractQuestion(lineText: String): String?`, `PairyDetector.buildContext(lines: List<String>, lineIndex: Int, contextLines: Int, filename: String, filetype: String): String`, `PairyDetector.findAtCursor(editor: Editor, contextLines: Int): PairComment?`, `PairyDetector.findAll(editor: Editor, contextLines: Int): List<PairComment>` — used by Task 6's actions.

- [ ] **Step 1: Write the failing test**

`jetbrains-plugin/src/test/kotlin/pairy/PairyDetectorTest.kt`:

```kotlin
package pairy

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class PairyDetectorTest {

    @Test
    fun `standalone comment matches all four styles`() {
        assertEquals("should this be a class?", PairyDetector.extractQuestion("-- pair: should this be a class?"))
        assertEquals("is this O(n)?", PairyDetector.extractQuestion("# pair: is this O(n)?"))
        assertEquals("why async here?", PairyDetector.extractQuestion("// pair: why async here?"))
        assertEquals("nil check needed?", PairyDetector.extractQuestion("/* pair: nil check needed? */"))
    }

    @Test
    fun `inline comment with code before the marker`() {
        val question = PairyDetector.extractQuestion(
            "result = sorted(items, key=lambda x: x.score)  # pair: is this O(n log n)?"
        )
        assertEquals("is this O(n log n)?", question)
    }

    @Test
    fun `indented standalone comment`() {
        assertEquals("edge case?", PairyDetector.extractQuestion("    # pair: edge case?"))
    }

    @Test
    fun `question text is trimmed`() {
        assertEquals("trimmed", PairyDetector.extractQuestion("#   pair:    trimmed   "))
    }

    @Test
    fun `lines without a comment marker do not match`() {
        assertNull(PairyDetector.extractQuestion("this line just says pair: nothing"))
        assertNull(PairyDetector.extractQuestion("pair: no marker at all"))
        assertNull(PairyDetector.extractQuestion("def pairing(): pass"))
    }

    @Test
    fun `find at cursor exactly on the pair line`() {
        val lines = listOf("def f():", "    x = 1  # pair: is x needed?", "    return x")
        val result = PairyDetector.findAtCursorInLines(lines, 1, 20, "f.py", "python")
        assertEquals(1, result?.lineIndex)
        assertEquals("is x needed?", result?.question)
    }

    @Test
    fun `find at cursor scans up to 3 lines above`() {
        val lines = listOf("# pair: three above", "a", "b", "c")
        val result = PairyDetector.findAtCursorInLines(lines, 3, 20, "f.py", "python")
        assertEquals(0, result?.lineIndex)
    }

    @Test
    fun `find at cursor does not scan more than 3 lines up`() {
        val lines = listOf("# pair: four above", "a", "b", "c", "d")
        assertNull(PairyDetector.findAtCursorInLines(lines, 4, 20, "f.py", "python"))
    }

    @Test
    fun `find at cursor returns null when nothing nearby`() {
        val lines = listOf("a", "b", "c")
        assertNull(PairyDetector.findAtCursorInLines(lines, 2, 20, "f.py", "python"))
    }

    @Test
    fun `find at cursor on line zero does not scan negative indices`() {
        val lines = listOf("# pair: first line")
        val result = PairyDetector.findAtCursorInLines(lines, 0, 20, "f.py", "python")
        assertEquals(0, result?.lineIndex)
    }

    @Test
    fun `find all returns every comment in order`() {
        val lines = listOf("# pair: first", "code", "// pair: second")
        val results = PairyDetector.findAllInLines(lines, 20, "f.py", "python")
        assertEquals(2, results.size)
        assertEquals("first", results[0].question)
        assertEquals("second", results[1].question)
    }

    @Test
    fun `find all returns empty list when nothing matches`() {
        val lines = listOf("a", "b", "c")
        assertTrue(PairyDetector.findAllInLines(lines, 20, "f.py", "python").isEmpty())
    }

    @Test
    fun `build context marks the pair line with greater-than`() {
        val lines = listOf("a", "# pair: q", "c")
        val context = PairyDetector.buildContext(lines, 1, 20, "f.py", "python")
        assertTrue(context.contains("> 2: # pair: q"))
        assertTrue(context.contains("  1: a"))
    }

    @Test
    fun `build context at line zero has no lines above`() {
        val lines = listOf("# pair: q", "b")
        val context = PairyDetector.buildContext(lines, 0, 20, "f.py", "python")
        assertTrue(context.contains("Lines 1-2"))
    }

    @Test
    fun `build context at last line has no lines below`() {
        val lines = listOf("a", "# pair: q")
        val context = PairyDetector.buildContext(lines, 1, 20, "f.py", "python")
        assertTrue(context.contains("Lines 1-2"))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./gradlew test --tests "pairy.PairyDetectorTest"`
Expected: FAIL — `PairyDetector` is unresolved.

- [ ] **Step 3: Write `PairyDetector.kt`**

```kotlin
package pairy

import com.intellij.openapi.editor.Editor
import com.intellij.openapi.util.TextRange

object PairyDetector {

    data class PairComment(
        val lineIndex: Int,
        val lineText: String,
        val question: String,
        val context: String
    )

    private val PAIR_PATTERNS = listOf(
        Regex("^.*?-{2,}\\s*pair:\\s*(.+)$"),   // Lua-style: --
        Regex("^.*?#+\\s*pair:\\s*(.+)$"),      // Ruby/Python/shell: #
        Regex("^.*?/{2,}\\s*pair:\\s*(.+)$"),   // JS/TS/Rust/Go: //
        Regex("^.*?/\\*+\\s*pair:\\s*(.+)$")    // C block: /*
    )

    fun extractQuestion(lineText: String): String? {
        for (pattern in PAIR_PATTERNS) {
            val match = pattern.find(lineText)
            if (match != null) return match.groupValues[1].trim()
        }
        return null
    }

    fun buildContext(
        lines: List<String>,
        lineIndex: Int,
        contextLines: Int,
        filename: String,
        filetype: String
    ): String {
        val start = maxOf(0, lineIndex - contextLines)
        val end = minOf(lines.size, lineIndex + contextLines + 1)
        val width = end.toString().length

        val numbered = (start until end).joinToString("\n") { i ->
            val marker = if (i == lineIndex) ">" else " "
            val lineNumber = (i + 1).toString().padStart(width)
            "$marker $lineNumber: ${lines[i]}"
        }

        val header = "File: $filename (${filetype.ifBlank { "text" }})\nLines ${start + 1}-$end:\n"
        return "$header```$filetype\n$numbered\n```"
    }

    fun findAllInLines(
        lines: List<String>,
        contextLines: Int,
        filename: String,
        filetype: String
    ): List<PairComment> {
        val results = mutableListOf<PairComment>()
        for (i in lines.indices) {
            val question = extractQuestion(lines[i])
            if (question != null) {
                results.add(
                    PairComment(i, lines[i], question, buildContext(lines, i, contextLines, filename, filetype))
                )
            }
        }
        return results
    }

    fun findAtCursorInLines(
        lines: List<String>,
        cursorLineIndex: Int,
        contextLines: Int,
        filename: String,
        filetype: String
    ): PairComment? {
        for (offset in 0..3) {
            val lineIndex = cursorLineIndex - offset
            if (lineIndex < 0) break
            val question = extractQuestion(lines[lineIndex])
            if (question != null) {
                return PairComment(
                    lineIndex, lines[lineIndex], question,
                    buildContext(lines, lineIndex, contextLines, filename, filetype)
                )
            }
        }
        return null
    }

    private fun documentLines(editor: Editor): List<String> {
        val document = editor.document
        return (0 until document.lineCount).map { i ->
            document.getText(TextRange(document.getLineStartOffset(i), document.getLineEndOffset(i)))
        }
    }

    fun findAtCursor(editor: Editor, contextLines: Int): PairComment? {
        val lines = documentLines(editor)
        val caretLine = editor.caretModel.logicalPosition.line
        val filename = editor.virtualFile?.name ?: "[unnamed]"
        val filetype = editor.virtualFile?.extension ?: ""
        return findAtCursorInLines(lines, caretLine, contextLines, filename, filetype)
    }

    fun findAll(editor: Editor, contextLines: Int): List<PairComment> {
        val lines = documentLines(editor)
        val filename = editor.virtualFile?.name ?: "[unnamed]"
        val filetype = editor.virtualFile?.extension ?: ""
        return findAllInLines(lines, contextLines, filename, filetype)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `./gradlew test --tests "pairy.PairyDetectorTest"`
Expected: PASS, 14 tests. (`findAtCursor`/`findAll`, the `Editor`-dependent wrappers, aren't covered here — no platform test fixtures in this project; they're exercised manually in Task 7.)

- [ ] **Step 5: Commit**

```bash
cd ~/Desktop/Programming/2026_Q1_Projects/pairy
git add jetbrains-plugin/src/main/kotlin/pairy/PairyDetector.kt jetbrains-plugin/src/test/kotlin/pairy/PairyDetectorTest.kt
git commit -m "feat(jetbrains): detect and format pair: comments"
```

---

### Task 4: PairyClient — Gemini API request/response

**Files:**
- Create: `jetbrains-plugin/src/main/kotlin/pairy/PairyClient.kt`
- Test: `jetbrains-plugin/src/test/kotlin/pairy/PairyClientTest.kt`

**Interfaces:**
- Consumes: nothing
- Produces: `sealed class PairyResult { data class Success(val text: String); data class Failure(val message: String) }`, `PairyClient.buildRequestBody(question: String, context: String, maxTokens: Int): String`, `PairyClient.parseResponse(responseBody: String): PairyResult`, `PairyClient.sendAsync(question: String, context: String, model: String, apiKey: String, maxTokens: Int): CompletableFuture<PairyResult>` — used by Task 6's `PairyDispatcher`.

- [ ] **Step 1: Write the failing test**

`jetbrains-plugin/src/test/kotlin/pairy/PairyClientTest.kt`:

```kotlin
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./gradlew test --tests "pairy.PairyClientTest"`
Expected: FAIL — `PairyClient` is unresolved.

- [ ] **Step 3: Write `PairyClient.kt`**

```kotlin
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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `./gradlew test --tests "pairy.PairyClientTest"`
Expected: PASS, 5 tests. (`sendAsync` makes a real network call — not unit tested; exercised manually in Task 7.)

- [ ] **Step 5: Commit**

```bash
cd ~/Desktop/Programming/2026_Q1_Projects/pairy
git add jetbrains-plugin/src/main/kotlin/pairy/PairyClient.kt jetbrains-plugin/src/test/kotlin/pairy/PairyClientTest.kt
git commit -m "feat(jetbrains): Gemini API request/response handling"
```

---

### Task 5: PairyRenderer — inline response rendering via Inlay

**Files:**
- Create: `jetbrains-plugin/src/main/kotlin/pairy/PairyTextUtil.kt`
- Create: `jetbrains-plugin/src/main/kotlin/pairy/PairyRenderer.kt`
- Test: `jetbrains-plugin/src/test/kotlin/pairy/PairyTextUtilTest.kt`

**Interfaces:**
- Consumes: nothing
- Produces: `PairyTextUtil.wrap(text: String, width: Int = 80): String`, `PairyRenderer.showPending(editor: Editor, lineIndex: Int)`, `PairyRenderer.showResponse(editor: Editor, lineIndex: Int, wrappedText: String)`, `PairyRenderer.showError(editor: Editor, lineIndex: Int, message: String)`, `PairyRenderer.clearLine(editor: Editor, lineIndex: Int)`, `PairyRenderer.clearAll(editor: Editor)` — used by Task 6's `PairyDispatcher` and actions.

- [ ] **Step 1: Write the failing test for text wrapping**

`jetbrains-plugin/src/test/kotlin/pairy/PairyTextUtilTest.kt`:

```kotlin
package pairy

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test

class PairyTextUtilTest {

    @Test
    fun `wraps text at the given width`() {
        val wrapped = PairyTextUtil.wrap("one two three four five", width = 13)
        assertEquals("one two three\nfour five", wrapped)
    }

    @Test
    fun `single word longer than width stays intact`() {
        assertEquals("supercalifragilisticexpialidocious", PairyTextUtil.wrap("supercalifragilisticexpialidocious", width = 10))
    }

    @Test
    fun `empty string returns empty string`() {
        assertEquals("", PairyTextUtil.wrap("", width = 80))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./gradlew test --tests "pairy.PairyTextUtilTest"`
Expected: FAIL — `PairyTextUtil` is unresolved.

- [ ] **Step 3: Write `PairyTextUtil.kt`**

```kotlin
package pairy

object PairyTextUtil {
    fun wrap(text: String, width: Int = 80): String {
        val words = text.split(Regex("\\s+")).filter { it.isNotEmpty() }
        if (words.isEmpty()) return ""

        val lines = mutableListOf<StringBuilder>()
        var current = StringBuilder()
        for (word in words) {
            when {
                current.isEmpty() -> current.append(word)
                current.length + 1 + word.length <= width -> current.append(' ').append(word)
                else -> {
                    lines.add(current)
                    current = StringBuilder(word)
                }
            }
        }
        if (current.isNotEmpty()) lines.add(current)
        return lines.joinToString("\n")
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `./gradlew test --tests "pairy.PairyTextUtilTest"`
Expected: PASS, 3 tests.

- [ ] **Step 5: Verify the local `EditorCustomElementRenderer` interface signature**

The exact method signatures on this interface (`paint`, `calcWidthInPixels`, `calcHeightInPixels`) can vary slightly across IntelliJ Platform versions. Check what your installed 2026.1.4 build actually expects before writing the renderer:

```bash
mkdir -p /tmp/pairy-check && cd /tmp/pairy-check
unzip -o -j /home/yashs/pycharm-2026.1.4/lib/intellij.platform.core.jar \
  'com/intellij/openapi/editor/EditorCustomElementRenderer.class'
javap EditorCustomElementRenderer.class
```

Compare the output against the method signatures used in `PairyBlockRenderer` below (`paint(Inlay<*>, Graphics, Rectangle, TextAttributes)`, `calcWidthInPixels(Inlay<*>): Int`, `calcHeightInPixels(Inlay<*>): Int`). If they differ (e.g. `Rectangle2D` instead of `Rectangle`, or a renamed parameter type), adjust the `override fun` signatures in Step 6 to match exactly. The Kotlin compiler will fail with "... overrides nothing" if they don't line up — treat a clean `./gradlew compileKotlin` as confirmation this step is done correctly.

- [ ] **Step 6: Write `PairyRenderer.kt`**

```kotlin
package pairy

import com.intellij.openapi.editor.Editor
import com.intellij.openapi.editor.EditorCustomElementRenderer
import com.intellij.openapi.editor.Inlay
import com.intellij.openapi.editor.colors.EditorFontType
import com.intellij.openapi.editor.markup.TextAttributes
import java.awt.Graphics
import java.awt.Rectangle

private const val PAIRY_PENDING_TEXT = "pairy: thinking…"

class PairyBlockRenderer(private var text: String) : EditorCustomElementRenderer {

    fun updateText(newText: String) {
        text = newText
    }

    override fun calcWidthInPixels(inlay: Inlay<*>): Int {
        val editor = inlay.editor
        val metrics = editor.contentComponent.getFontMetrics(editor.colorsScheme.getFont(EditorFontType.ITALIC))
        return text.lineSequence().maxOf { metrics.stringWidth(it) } + 10
    }

    override fun calcHeightInPixels(inlay: Inlay<*>): Int {
        val lineCount = text.lineSequence().count().coerceAtLeast(1)
        return inlay.editor.lineHeight * lineCount
    }

    override fun paint(inlay: Inlay<*>, g: Graphics, targetRegion: Rectangle, textAttributes: TextAttributes) {
        val editor = inlay.editor
        g.color = editor.colorsScheme.defaultForeground.darker()
        g.font = editor.colorsScheme.getFont(EditorFontType.ITALIC)
        val lineHeight = editor.lineHeight
        val ascent = g.fontMetrics.ascent
        text.lineSequence().forEachIndexed { index, line ->
            g.drawString(line, targetRegion.x + 4, targetRegion.y + ascent + index * lineHeight)
        }
    }
}

object PairyRenderer {
    private val inlaysByEditor = mutableMapOf<Editor, MutableMap<Int, Inlay<PairyBlockRenderer>>>()

    private fun inlaysFor(editor: Editor) = inlaysByEditor.getOrPut(editor) { mutableMapOf() }

    private fun upsert(editor: Editor, lineIndex: Int, text: String) {
        val existing = inlaysFor(editor)[lineIndex]
        if (existing != null && existing.isValid) {
            existing.renderer.updateText(text)
            existing.update()
            return
        }
        val offset = editor.document.getLineEndOffset(lineIndex)
        val inlay = editor.inlayModel.addBlockElement(offset, true, false, 0, PairyBlockRenderer(text)) ?: return
        inlaysFor(editor)[lineIndex] = inlay
    }

    fun showPending(editor: Editor, lineIndex: Int) = upsert(editor, lineIndex, PAIRY_PENDING_TEXT)

    fun showResponse(editor: Editor, lineIndex: Int, wrappedText: String) = upsert(editor, lineIndex, wrappedText)

    fun showError(editor: Editor, lineIndex: Int, message: String) = upsert(editor, lineIndex, "pairy error: $message")

    fun clearLine(editor: Editor, lineIndex: Int) {
        inlaysFor(editor).remove(lineIndex)?.dispose()
    }

    fun clearAll(editor: Editor) {
        inlaysFor(editor).values.forEach { it.dispose() }
        inlaysFor(editor).clear()
    }
}
```

- [ ] **Step 7: Compile and fix any signature mismatch**

Run: `./gradlew compileKotlin`
Expected: `BUILD SUCCESSFUL`. If it fails on the `EditorCustomElementRenderer` overrides, apply the fix identified in Step 5 and re-run until clean.

- [ ] **Step 8: Commit**

```bash
cd ~/Desktop/Programming/2026_Q1_Projects/pairy
git add jetbrains-plugin/src/main/kotlin/pairy/PairyTextUtil.kt jetbrains-plugin/src/main/kotlin/pairy/PairyRenderer.kt \
        jetbrains-plugin/src/test/kotlin/pairy/PairyTextUtilTest.kt
git commit -m "feat(jetbrains): render responses as inline read-only text"
```

---

### Task 6: PairyDispatcher, actions, and plugin.xml wiring

**Files:**
- Create: `jetbrains-plugin/src/main/kotlin/pairy/PairyNotifier.kt`
- Create: `jetbrains-plugin/src/main/kotlin/pairy/PairyDispatcher.kt`
- Create: `jetbrains-plugin/src/main/kotlin/pairy/PairySendAction.kt`
- Create: `jetbrains-plugin/src/main/kotlin/pairy/PairyRetryAction.kt`
- Create: `jetbrains-plugin/src/main/kotlin/pairy/PairySendAllAction.kt`
- Create: `jetbrains-plugin/src/main/kotlin/pairy/PairyClearAction.kt`
- Create: `jetbrains-plugin/src/main/kotlin/pairy/PairyClearAllAction.kt`
- Create: `jetbrains-plugin/src/main/kotlin/pairy/PairyCancelAction.kt`
- Modify: `jetbrains-plugin/src/main/resources/META-INF/plugin.xml`

**Interfaces:**
- Consumes: `PairyConfig.load()`, `PairyConfigData` (Task 2); `PairyDetector.PairComment`, `.findAtCursor()`, `.findAll()` (Task 3); `PairyResult`, `PairyClient.sendAsync()` (Task 4); `PairyTextUtil.wrap()`, `PairyRenderer.*` (Task 5)
- Produces: six registered `AnAction` classes wired to keyboard shortcuts, and `PairyDispatcher.dispatch()`/`.cancel()`/`.requireApiKey()` — this is the last code task; nothing downstream depends on it besides manual verification (Task 7) and packaging (Task 8).

- [ ] **Step 1: Write `PairyNotifier.kt`**

```kotlin
package pairy

import com.intellij.notification.NotificationGroupManager
import com.intellij.notification.NotificationType
import com.intellij.openapi.project.Project

object PairyNotifier {
    private const val GROUP_ID = "Pairy"

    fun error(project: Project, message: String) {
        NotificationGroupManager.getInstance()
            .getNotificationGroup(GROUP_ID)
            .createNotification(message, NotificationType.ERROR)
            .notify(project)
    }

    fun warn(project: Project, message: String) {
        NotificationGroupManager.getInstance()
            .getNotificationGroup(GROUP_ID)
            .createNotification(message, NotificationType.WARNING)
            .notify(project)
    }
}
```

- [ ] **Step 2: Write `PairyDispatcher.kt`**

```kotlin
package pairy

import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.editor.Editor
import com.intellij.openapi.project.Project
import java.util.concurrent.CancellationException
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap

object PairyDispatcher {
    private val inFlight = ConcurrentHashMap<Pair<Editor, Int>, CompletableFuture<PairyResult>>()

    fun requireApiKey(project: Project, config: PairyConfigData): Boolean {
        if (config.apiKey.isBlank()) {
            PairyNotifier.error(project, "No API key. Add 'api_key' to ~/.config/pairy/config.json")
            return false
        }
        return true
    }

    fun dispatch(project: Project, editor: Editor, comment: PairyDetector.PairComment, config: PairyConfigData) {
        val key = editor to comment.lineIndex
        inFlight[key]?.cancel(true)
        PairyRenderer.showPending(editor, comment.lineIndex)

        val future = PairyClient.sendAsync(comment.question, comment.context, config.model, config.apiKey, config.maxTokens)
        inFlight[key] = future

        future.whenComplete { result, throwable ->
            inFlight.remove(key)
            ApplicationManager.getApplication().invokeLater {
                if (throwable != null) {
                    if (throwable !is CancellationException) {
                        PairyRenderer.showError(editor, comment.lineIndex, throwable.message ?: "Unknown error")
                    }
                    return@invokeLater
                }
                when (result) {
                    is PairyResult.Success ->
                        PairyRenderer.showResponse(editor, comment.lineIndex, PairyTextUtil.wrap(result.text))
                    is PairyResult.Failure -> {
                        PairyRenderer.showError(editor, comment.lineIndex, result.message)
                        PairyNotifier.error(project, result.message)
                    }
                }
            }
        }
    }

    fun cancel(editor: Editor, lineIndex: Int) {
        inFlight.remove(editor to lineIndex)?.cancel(true)
    }
}
```

- [ ] **Step 3: Write the six action classes**

`jetbrains-plugin/src/main/kotlin/pairy/PairySendAction.kt`:

```kotlin
package pairy

import com.intellij.openapi.actionSystem.ActionUpdateThread
import com.intellij.openapi.actionSystem.AnAction
import com.intellij.openapi.actionSystem.AnActionEvent
import com.intellij.openapi.actionSystem.CommonDataKeys
import com.intellij.openapi.ui.Messages

class PairySendAction : AnAction() {
    override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.BGT

    override fun actionPerformed(e: AnActionEvent) {
        val project = e.project ?: return
        val editor = e.getData(CommonDataKeys.EDITOR) ?: return
        val config = PairyConfig.load()
        if (!PairyDispatcher.requireApiKey(project, config)) return

        val selection = editor.selectionModel.selectedText
        val caretLine = editor.caretModel.logicalPosition.line

        val comment = if (!selection.isNullOrBlank()) {
            val question = Messages.showInputDialog(project, "Ask about the selection:", "Pairy", null) ?: return
            PairyDetector.PairComment(caretLine, "", question, "```\n$selection\n```")
        } else {
            PairyDetector.findAtCursor(editor, config.contextLines) ?: run {
                PairyNotifier.warn(project, "No pair: comment found near the cursor")
                return
            }
        }

        PairyDispatcher.dispatch(project, editor, comment, config)
    }
}
```

`jetbrains-plugin/src/main/kotlin/pairy/PairyRetryAction.kt`:

```kotlin
package pairy

import com.intellij.openapi.actionSystem.ActionUpdateThread
import com.intellij.openapi.actionSystem.AnAction
import com.intellij.openapi.actionSystem.AnActionEvent
import com.intellij.openapi.actionSystem.CommonDataKeys

class PairyRetryAction : AnAction() {
    override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.BGT

    override fun actionPerformed(e: AnActionEvent) {
        val project = e.project ?: return
        val editor = e.getData(CommonDataKeys.EDITOR) ?: return
        val config = PairyConfig.load()
        if (!PairyDispatcher.requireApiKey(project, config)) return

        val comment = PairyDetector.findAtCursor(editor, config.contextLines) ?: run {
            PairyNotifier.warn(project, "No pair: comment found near the cursor")
            return
        }
        PairyDispatcher.dispatch(project, editor, comment, config)
    }
}
```

`jetbrains-plugin/src/main/kotlin/pairy/PairySendAllAction.kt`:

```kotlin
package pairy

import com.intellij.openapi.actionSystem.ActionUpdateThread
import com.intellij.openapi.actionSystem.AnAction
import com.intellij.openapi.actionSystem.AnActionEvent
import com.intellij.openapi.actionSystem.CommonDataKeys

class PairySendAllAction : AnAction() {
    override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.BGT

    override fun actionPerformed(e: AnActionEvent) {
        val project = e.project ?: return
        val editor = e.getData(CommonDataKeys.EDITOR) ?: return
        val config = PairyConfig.load()
        if (!PairyDispatcher.requireApiKey(project, config)) return

        val comments = PairyDetector.findAll(editor, config.contextLines)
        if (comments.isEmpty()) {
            PairyNotifier.warn(project, "No pair: comments found in this file")
            return
        }
        comments.forEach { comment -> PairyDispatcher.dispatch(project, editor, comment, config) }
    }
}
```

`jetbrains-plugin/src/main/kotlin/pairy/PairyClearAction.kt`:

```kotlin
package pairy

import com.intellij.openapi.actionSystem.ActionUpdateThread
import com.intellij.openapi.actionSystem.AnAction
import com.intellij.openapi.actionSystem.AnActionEvent
import com.intellij.openapi.actionSystem.CommonDataKeys

class PairyClearAction : AnAction() {
    override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.BGT

    override fun actionPerformed(e: AnActionEvent) {
        val editor = e.getData(CommonDataKeys.EDITOR) ?: return
        val line = editor.caretModel.logicalPosition.line
        PairyDispatcher.cancel(editor, line)
        PairyRenderer.clearLine(editor, line)
    }
}
```

`jetbrains-plugin/src/main/kotlin/pairy/PairyClearAllAction.kt`:

```kotlin
package pairy

import com.intellij.openapi.actionSystem.ActionUpdateThread
import com.intellij.openapi.actionSystem.AnAction
import com.intellij.openapi.actionSystem.AnActionEvent
import com.intellij.openapi.actionSystem.CommonDataKeys

class PairyClearAllAction : AnAction() {
    override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.BGT

    override fun actionPerformed(e: AnActionEvent) {
        val editor = e.getData(CommonDataKeys.EDITOR) ?: return
        PairyRenderer.clearAll(editor)
    }
}
```

`jetbrains-plugin/src/main/kotlin/pairy/PairyCancelAction.kt`:

```kotlin
package pairy

import com.intellij.openapi.actionSystem.ActionUpdateThread
import com.intellij.openapi.actionSystem.AnAction
import com.intellij.openapi.actionSystem.AnActionEvent
import com.intellij.openapi.actionSystem.CommonDataKeys

class PairyCancelAction : AnAction() {
    override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.BGT

    override fun actionPerformed(e: AnActionEvent) {
        val editor = e.getData(CommonDataKeys.EDITOR) ?: return
        val line = editor.caretModel.logicalPosition.line
        PairyDispatcher.cancel(editor, line)
        PairyRenderer.clearLine(editor, line)
    }
}
```

- [ ] **Step 4: Register the notification group and actions in `plugin.xml`**

Replace the contents of `jetbrains-plugin/src/main/resources/META-INF/plugin.xml` with:

```xml
<idea-plugin>
    <id>dev.yashsrivastava19.pairy</id>
    <name>Pairy</name>
    <vendor>yash-srivastava19</vendor>
    <description>AI pair programming inside the editor. Write a pair: comment, get a response as inline text, never written to the file.</description>

    <depends>com.intellij.modules.platform</depends>

    <extensions defaultExtensionNs="com.intellij">
        <notificationGroup id="Pairy" displayType="BALLOON"/>
    </extensions>

    <actions>
        <group id="Pairy.Actions" text="Pairy" popup="true">
            <add-to-group group-id="ToolsMenu" anchor="last"/>

            <action id="Pairy.Send" class="pairy.PairySendAction" text="Send"
                    description="Send the pair: comment at cursor, or ask about the selection">
                <keyboard-shortcut first-keystroke="ctrl alt P" second-keystroke="S" keymap="$default"/>
            </action>
            <action id="Pairy.Retry" class="pairy.PairyRetryAction" text="Retry"
                    description="Re-send the pair: comment at cursor">
                <keyboard-shortcut first-keystroke="ctrl alt P" second-keystroke="R" keymap="$default"/>
            </action>
            <action id="Pairy.SendAll" class="pairy.PairySendAllAction" text="Send All"
                    description="Send every pair: comment in the file">
                <keyboard-shortcut first-keystroke="ctrl alt P" second-keystroke="A" keymap="$default"/>
            </action>
            <action id="Pairy.Clear" class="pairy.PairyClearAction" text="Clear"
                    description="Clear the response at cursor">
                <keyboard-shortcut first-keystroke="ctrl alt P" second-keystroke="X" keymap="$default"/>
            </action>
            <action id="Pairy.ClearAll" class="pairy.PairyClearAllAction" text="Clear All"
                    description="Clear all responses in the file">
                <keyboard-shortcut first-keystroke="ctrl alt P" second-keystroke="C" keymap="$default"/>
            </action>
            <action id="Pairy.Cancel" class="pairy.PairyCancelAction" text="Cancel"
                    description="Cancel the in-flight request at cursor">
                <keyboard-shortcut first-keystroke="ctrl alt P" second-keystroke="K" keymap="$default"/>
            </action>
        </group>
    </actions>
</idea-plugin>
```

- [ ] **Step 5: Build to confirm everything compiles and the plugin descriptor is valid**

Run: `./gradlew build`
Expected: `BUILD SUCCESSFUL`, including `verifyPluginProjectConfiguration`/`patchPluginXml`-equivalent checks the IntelliJ Platform Gradle Plugin runs as part of `build`.

- [ ] **Step 6: Commit**

```bash
cd ~/Desktop/Programming/2026_Q1_Projects/pairy
git add jetbrains-plugin/src/main/kotlin/pairy/PairyNotifier.kt jetbrains-plugin/src/main/kotlin/pairy/PairyDispatcher.kt \
        jetbrains-plugin/src/main/kotlin/pairy/PairySendAction.kt jetbrains-plugin/src/main/kotlin/pairy/PairyRetryAction.kt \
        jetbrains-plugin/src/main/kotlin/pairy/PairySendAllAction.kt jetbrains-plugin/src/main/kotlin/pairy/PairyClearAction.kt \
        jetbrains-plugin/src/main/kotlin/pairy/PairyClearAllAction.kt jetbrains-plugin/src/main/kotlin/pairy/PairyCancelAction.kt \
        jetbrains-plugin/src/main/resources/META-INF/plugin.xml
git commit -m "feat(jetbrains): wire up Send/Retry/SendAll/Clear/ClearAll/Cancel actions"
```

---

### Task 7: Manual verification in a sandboxed IDE

**Files:** none (verification only)

**Interfaces:**
- Consumes: the fully-wired plugin from Task 6
- Produces: confidence the plugin works end-to-end before installing it into your real PyCharm

- [ ] **Step 1: Launch the sandbox**

Run: `./gradlew runIde`

Expected: a second PyCharm window opens (sandboxed profile, separate from your real config/plugins). First run downloads additional platform artifacts and can take several minutes.

- [ ] **Step 2: Create a test file and verify Send**

In the sandbox, create `scratch.py`:

```python
def total(items):
    # pair: should this handle an empty list explicitly?
    return sum(items)
```

Place the cursor on the `pair:` line. Press `Ctrl+Alt+P`, release, then press `S`.

Expected: a gray italic "pairy: thinking…" block appears directly below the line, then within a few seconds is replaced by a real response from Gemini (this is a live API call using your real `~/.config/pairy/config.json`, since the sandbox shares your `$HOME`).

- [ ] **Step 3: Verify Retry**

With the cursor still on the `pair:` line, press `Ctrl+Alt+P` then `R`.

Expected: the inlay shows "thinking…" again, then updates with a (possibly different) response.

- [ ] **Step 4: Verify Clear**

Press `Ctrl+Alt+P` then `X`.

Expected: the inlay disappears entirely.

- [ ] **Step 5: Verify Send All and Clear All**

Add a second line: `x = 1  # pair: is this the right variable name?`. Press `Ctrl+Alt+P` then `A`.

Expected: both `pair:` lines get their own response inlays.

Press `Ctrl+Alt+P` then `C`.

Expected: both inlays disappear.

- [ ] **Step 6: Verify Cancel**

Trigger Send on a line (`Ctrl+Alt+P` then `S`), and within a second, before the response arrives, press `Ctrl+Alt+P` then `K`.

Expected: the "thinking…" inlay disappears and no response ever appears for that line afterward.

- [ ] **Step 7: Verify the file itself is never modified**

Run (in a separate terminal, from the sandbox's working directory — wherever `scratch.py` was saved): `git status` or check the file's modification indicator in the editor gutter.

Expected: no diff attributable to Pairy — the file's actual text content is byte-for-byte what you typed, regardless of how many inlays were shown/cleared.

- [ ] **Step 8: Verify the missing-API-key error path**

Temporarily rename your config so it can't be found:

```bash
mv ~/.config/pairy/config.json ~/.config/pairy/config.json.bak
```

In the sandbox, trigger Send on a `pair:` line.

Expected: an error notification reading "No API key. Add 'api_key' to ~/.config/pairy/config.json" — no crash, no inlay.

Restore your config:

```bash
mv ~/.config/pairy/config.json.bak ~/.config/pairy/config.json
```

- [ ] **Step 9: Close the sandbox**

Close the sandboxed PyCharm window. No commit for this task — it's verification only, not a code change.

---

### Task 8: Build the distributable plugin and install it into real PyCharm

**Files:** none (packaging and manual install)

**Interfaces:**
- Consumes: the verified plugin from Task 7
- Produces: Pairy running inside your actual PyCharm 2026.1.4 install

- [ ] **Step 1: Build the plugin zip**

Run: `./gradlew buildPlugin`

Expected: `BUILD SUCCESSFUL`, and a zip appears at `jetbrains-plugin/build/distributions/pairy-jetbrains-0.1.0.zip` (confirm the exact name with `ls jetbrains-plugin/build/distributions/`).

- [ ] **Step 2: Install into your real PyCharm**

Launch your actual PyCharm (`~/.local/bin/pycharm` or `/home/yashs/pycharm-2026.1.4/bin/pycharm.sh`). Go to **Settings → Plugins → gear icon (⚙) → Install Plugin from Disk…**, and select the zip from Step 1.

Expected: a one-time "installing a plugin not from the Marketplace" warning — this is expected for an unsigned local install; accept it.

- [ ] **Step 3: Restart PyCharm when prompted**

- [ ] **Step 4: Smoke-test in your real project**

Open any real Python file, add a `pair:` comment, and run through Send/Retry/Clear at minimum (the same steps as Task 7, Steps 2–4) to confirm the plugin behaves identically outside the sandbox.

- [ ] **Step 5: Done**

No commit — this task is a local install action, not a repo change. Pairy is now running in your PyCharm.

---

## Self-Review Notes

- **Spec coverage:** every in-scope item from the design spec (Send/Retry/SendAll/Clear/ClearAll/Cancel, selection-based questions, config reuse, non-streaming, never-written-to-file, local install) has a task. Deferred items (threading, `PAIRY.md`, session save, hover inspect, yank/toggle, streaming) are explicitly not implemented anywhere in this plan, matching the spec's exclusions.
- **Type consistency checked:** `PairyConfigData`, `PairyDetector.PairComment`, `PairyResult`, and all `PairyRenderer`/`PairyDispatcher` function signatures are used identically across Tasks 2–6 wherever referenced.
- **JDK/Gradle risk called out explicitly** in Task 1 rather than assumed away, since the system only has JDK 26 and Gradle version support for brand-new JDKs can lag.
- **Platform API risk called out explicitly** in Task 5 (Step 5) rather than assumed away, since exact `EditorCustomElementRenderer` signatures can drift between IntelliJ Platform versions — compilation against the real local platform jar is the acceptance check.
