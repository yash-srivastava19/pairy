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
