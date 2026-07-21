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
