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
