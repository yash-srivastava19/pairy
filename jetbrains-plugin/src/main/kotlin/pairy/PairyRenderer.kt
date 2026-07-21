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
