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
        for ((index, pattern) in PAIR_PATTERNS.withIndex()) {
            val match = pattern.find(lineText)
            if (match != null) {
                var question = match.groupValues[1].trim()
                if (index == 3) {
                    question = question.removeSuffix("*/").trim()
                }
                return question
            }
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
