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
