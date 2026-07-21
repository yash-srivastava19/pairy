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
