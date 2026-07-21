package pairy

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test

class PairyDetectorTest {

    @Test
    fun `standalone comment matches all four styles`() {
        assertEquals("should this be a class?", PairyDetector.extractQuestion("-- pair: should this be a class?"))
        assertEquals("is this O(n)?", PairyDetector.extractQuestion("# pair: is this O(n)?"))
        assertEquals("why async here?", PairyDetector.extractQuestion("// pair: why async here?"))
        assertEquals("nil check needed?", PairyDetector.extractQuestion("/* pair: nil check needed? */"))
    }

    @Test
    fun `c block comment without a same-line closing delimiter still matches`() {
        assertEquals("unfinished thought", PairyDetector.extractQuestion("/* pair: unfinished thought"))
    }

    @Test
    fun `inline comment with code before the marker`() {
        val question = PairyDetector.extractQuestion(
            "result = sorted(items, key=lambda x: x.score)  # pair: is this O(n log n)?"
        )
        assertEquals("is this O(n log n)?", question)
    }

    @Test
    fun `indented standalone comment`() {
        assertEquals("edge case?", PairyDetector.extractQuestion("    # pair: edge case?"))
    }

    @Test
    fun `question text is trimmed`() {
        assertEquals("trimmed", PairyDetector.extractQuestion("#   pair:    trimmed   "))
    }

    @Test
    fun `lines without a comment marker do not match`() {
        assertNull(PairyDetector.extractQuestion("this line just says pair: nothing"))
        assertNull(PairyDetector.extractQuestion("pair: no marker at all"))
        assertNull(PairyDetector.extractQuestion("def pairing(): pass"))
    }

    @Test
    fun `find at cursor exactly on the pair line`() {
        val lines = listOf("def f():", "    x = 1  # pair: is x needed?", "    return x")
        val result = PairyDetector.findAtCursorInLines(lines, 1, 20, "f.py", "python")
        assertEquals(1, result?.lineIndex)
        assertEquals("is x needed?", result?.question)
    }

    @Test
    fun `find at cursor scans up to 3 lines above`() {
        val lines = listOf("# pair: three above", "a", "b", "c")
        val result = PairyDetector.findAtCursorInLines(lines, 3, 20, "f.py", "python")
        assertEquals(0, result?.lineIndex)
    }

    @Test
    fun `find at cursor does not scan more than 3 lines up`() {
        val lines = listOf("# pair: four above", "a", "b", "c", "d")
        assertNull(PairyDetector.findAtCursorInLines(lines, 4, 20, "f.py", "python"))
    }

    @Test
    fun `find at cursor returns null when nothing nearby`() {
        val lines = listOf("a", "b", "c")
        assertNull(PairyDetector.findAtCursorInLines(lines, 2, 20, "f.py", "python"))
    }

    @Test
    fun `find at cursor on line zero does not scan negative indices`() {
        val lines = listOf("# pair: first line")
        val result = PairyDetector.findAtCursorInLines(lines, 0, 20, "f.py", "python")
        assertEquals(0, result?.lineIndex)
    }

    @Test
    fun `find all returns every comment in order`() {
        val lines = listOf("# pair: first", "code", "// pair: second")
        val results = PairyDetector.findAllInLines(lines, 20, "f.py", "python")
        assertEquals(2, results.size)
        assertEquals("first", results[0].question)
        assertEquals("second", results[1].question)
    }

    @Test
    fun `find all returns empty list when nothing matches`() {
        val lines = listOf("a", "b", "c")
        assertTrue(PairyDetector.findAllInLines(lines, 20, "f.py", "python").isEmpty())
    }

    @Test
    fun `build context marks the pair line with greater-than`() {
        val lines = listOf("a", "# pair: q", "c")
        val context = PairyDetector.buildContext(lines, 1, 20, "f.py", "python")
        assertTrue(context.contains("> 2: # pair: q"))
        assertTrue(context.contains("  1: a"))
    }

    @Test
    fun `build context at line zero has no lines above`() {
        val lines = listOf("# pair: q", "b")
        val context = PairyDetector.buildContext(lines, 0, 20, "f.py", "python")
        assertTrue(context.contains("Lines 1-2"))
    }

    @Test
    fun `build context at last line has no lines below`() {
        val lines = listOf("a", "# pair: q")
        val context = PairyDetector.buildContext(lines, 1, 20, "f.py", "python")
        assertTrue(context.contains("Lines 1-2"))
    }
}
