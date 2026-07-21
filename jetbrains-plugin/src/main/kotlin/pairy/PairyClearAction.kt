package pairy

import com.intellij.openapi.actionSystem.ActionUpdateThread
import com.intellij.openapi.actionSystem.AnAction
import com.intellij.openapi.actionSystem.AnActionEvent
import com.intellij.openapi.actionSystem.CommonDataKeys

class PairyClearAction : AnAction() {
    override fun getActionUpdateThread(): ActionUpdateThread = ActionUpdateThread.BGT

    override fun actionPerformed(e: AnActionEvent) {
        val editor = e.getData(CommonDataKeys.EDITOR) ?: return
        val config = PairyConfig.load()
        val line = PairyDetector.findAtCursor(editor, config.contextLines)?.lineIndex
            ?: editor.caretModel.logicalPosition.line
        PairyDispatcher.cancel(editor, line)
        PairyRenderer.clearLine(editor, line)
    }
}
