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
