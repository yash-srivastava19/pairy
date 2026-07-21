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
