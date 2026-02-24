;;; pairy-test.el --- ERT tests for pairy.el  -*- lexical-binding: t -*-

;;; Commentary:
;; Run with:
;;   emacs --batch -l pairy.el -l tests/pairy-test.el -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)

;; Seed config so tests that call pairy--cfg don't need a real file.
(setq pairy--config
      '(:api-key "test-key" :model "gemini-test"
        :context-lines 3 :max-tokens 100))

;; ─── pairy--extract-question ─────────────────────────────────────────────

(ert-deftest pairy-extract-question/standalone-all-styles ()
  "Standalone pair: comments are matched in all four comment styles."
  (should (equal (pairy--extract-question "-- pair: lua")    "lua"))
  (should (equal (pairy--extract-question "--- pair: lua")   "lua"))
  (should (equal (pairy--extract-question "# pair: python")  "python"))
  (should (equal (pairy--extract-question "## pair: sh")     "sh"))
  (should (equal (pairy--extract-question "// pair: js")     "js"))
  (should (equal (pairy--extract-question "/// pair: rust")  "rust"))
  (should (equal (pairy--extract-question "/* pair: c")      "c")))

(ert-deftest pairy-extract-question/inline-code-before-marker ()
  "Inline end-of-line pair: comments are matched (the fixed bug)."
  (should (equal (pairy--extract-question "n * n * 2  # pair: is this right?")
                 "is this right?"))
  (should (equal (pairy--extract-question "result = foo()  # pair: nil check needed?")
                 "nil check needed?"))
  (should (equal (pairy--extract-question "x = 1  -- pair: lua inline")
                 "lua inline"))
  (should (equal (pairy--extract-question "let x = 1;  // pair: js inline")
                 "js inline"))
  (should (equal (pairy--extract-question "int x = 0;  /* pair: c inline")
                 "c inline")))

(ert-deftest pairy-extract-question/indented ()
  "Indented standalone comments are matched."
  (should (equal (pairy--extract-question "    # pair: indented python") "indented python"))
  (should (equal (pairy--extract-question "  -- pair: indented lua")    "indented lua"))
  (should (equal (pairy--extract-question "\t// pair: tabbed js")       "tabbed js")))

(ert-deftest pairy-extract-question/question-text-trimmed ()
  "Whitespace around the question text is stripped."
  (should (equal (pairy--extract-question "#  pair:   lots of spaces   ") "lots of spaces"))
  (should (equal (pairy--extract-question "//pair:no space after colon") "no space after colon")))

(ert-deftest pairy-extract-question/must-not-match ()
  "Lines without pair: comments return nil."
  (should-not (pairy--extract-question ""))
  (should-not (pairy--extract-question "# regular comment"))
  (should-not (pairy--extract-question "x = 1  # not a pair comment"))
  (should-not (pairy--extract-question "// pairings are not pair: comments"))
  (should-not (pairy--extract-question "pairing: something"))
  (should-not (pairy--extract-question "# pair:")))   ; empty question

;; ─── pairy--parse-sse-line ───────────────────────────────────────────────

(ert-deftest pairy-parse-sse-line/nil-cases ()
  "Non-data lines return nil."
  (should-not (pairy--parse-sse-line ""))
  (should-not (pairy--parse-sse-line "   "))
  (should-not (pairy--parse-sse-line ": keep-alive"))
  (should-not (pairy--parse-sse-line "event: content_block_start"))
  (should-not (pairy--parse-sse-line "not-data: something")))

(ert-deftest pairy-parse-sse-line/valid-gemini-delta ()
  "A real Gemini SSE line extracts the text content."
  (let ((line (concat "data: {\"candidates\": [{\"content\": "
                      "{\"parts\": [{\"text\": \"Handle it here.\"}],"
                      "\"role\": \"model\"},\"finishReason\": \"STOP\","
                      "\"index\": 0}]}")))
    (should (equal (pairy--parse-sse-line line) "Handle it here."))))

(ert-deftest pairy-parse-sse-line/api-error ()
  "An API error object returns the __ERROR__: prefix."
  (let ((line "data: {\"error\": {\"message\": \"API key invalid\", \"status\": \"UNAUTHENTICATED\"}}"))
    (should (equal (pairy--parse-sse-line line) "__ERROR__:API key invalid"))))

(ert-deftest pairy-parse-sse-line/malformed-json-no-crash ()
  "Malformed JSON returns nil without crashing."
  (should-not (pairy--parse-sse-line "data: {not valid json"))
  (should-not (pairy--parse-sse-line "data: null"))
  (should-not (pairy--parse-sse-line "data: 42")))

(ert-deftest pairy-parse-sse-line/partial-structure-nil ()
  "Partial or unexpected Gemini structure returns nil gracefully."
  (should-not (pairy--parse-sse-line "data: {}"))
  (should-not (pairy--parse-sse-line "data: {\"candidates\": []}"))
  (should-not (pairy--parse-sse-line
               "data: {\"candidates\": [{\"content\": {\"parts\": []}}]}")))

(ert-deftest pairy-parse-sse-line/whitespace-trimmed ()
  "Whitespace around the data: prefix is handled."
  (let ((line (concat "data:  {\"candidates\": [{\"content\": "
                      "{\"parts\": [{\"text\": \"trimmed\"}],"
                      "\"role\": \"model\"},\"index\": 0}]}")))
    (should (equal (pairy--parse-sse-line line) "trimmed"))))

;; Regression: the :array-type 'vector bug that caused "Empty response from API"
(ert-deftest pairy-parse-sse-line/array-type-regression ()
  "SSE parsing correctly handles arrays (regression: was broken by :array-type 'vector)."
  (let ((multi-token-line
         (concat "data: {\"candidates\": [{\"content\": "
                 "{\"parts\": [{\"text\": \"yes.\"}],"
                 "\"role\": \"model\"},\"finishReason\": \"STOP\",\"index\": 0}]}")))
    ;; This returned nil before the fix
    (should (stringp (pairy--parse-sse-line multi-token-line)))
    (should (equal  (pairy--parse-sse-line multi-token-line) "yes."))))

;; ─── pairy--find-at-point ────────────────────────────────────────────────

(ert-deftest pairy-find-at-point/cursor-on-pair-line ()
  "find-at-point succeeds when cursor is on the pair: line."
  (with-temp-buffer
    (insert "def foo():\n    # pair: is this right?\n    pass\n")
    (goto-char (point-min))
    (forward-line 1)
    (let ((found (pairy--find-at-point)))
      (should found)
      (should (= (car found) 2))
      (should (equal (cadr found) "is this right?")))))

(ert-deftest pairy-find-at-point/cursor-below-pair-line ()
  "find-at-point scans up to 3 lines above the cursor."
  (with-temp-buffer
    (insert "# pair: above\nline2\nline3\nline4\n")
    (goto-char (point-min))
    (forward-line 3)  ; cursor on line 4
    (should (pairy--find-at-point))
    (forward-line 1)  ; cursor on line 5 — 4 lines away, should NOT match
    (should-not (pairy--find-at-point))))

(ert-deftest pairy-find-at-point/no-pair-comment ()
  "find-at-point returns nil when no pair: comment is near cursor."
  (with-temp-buffer
    (insert "x = 1\ny = 2\nz = 3\n")
    (goto-char (point-min))
    (forward-line 2)
    (should-not (pairy--find-at-point))))

(ert-deftest pairy-find-at-point/inline-comment ()
  "find-at-point finds inline pair: comments."
  (with-temp-buffer
    (insert "result = n * n  # pair: is this O(n^2)?\n")
    (goto-char (point-min))
    (let ((found (pairy--find-at-point)))
      (should found)
      (should (equal (cadr found) "is this O(n^2)?")))))

(ert-deftest pairy-find-at-point/first-line-edge-case ()
  "find-at-point works when the pair: comment is on line 1."
  (with-temp-buffer
    (insert "# pair: first line question\ncode\n")
    (goto-char (point-min))
    (let ((found (pairy--find-at-point)))
      (should found)
      (should (= (car found) 1)))))

;; ─── pairy--build-context ────────────────────────────────────────────────

(ert-deftest pairy-build-context/marker-on-pair-line ()
  "build-context puts '>' marker on the pair: line."
  (with-temp-buffer
    (insert "line1\n# pair: question\nline3\n")
    (let ((ctx (pairy--build-context 2)))
      (should (string-match-p ">.*pair: question" ctx)))))

(ert-deftest pairy-build-context/other-lines-have-space ()
  "build-context uses ' ' marker on non-pair lines."
  (with-temp-buffer
    (insert "line1\n# pair: question\nline3\n")
    (let ((ctx (pairy--build-context 2)))
      (should (string-match-p "^ +1: line1" ctx))
      (should (string-match-p "^ +3: line3" ctx)))))

(ert-deftest pairy-build-context/includes-header ()
  "build-context includes the file/language header."
  (with-temp-buffer
    (insert "x = 1\n# pair: q\n")
    (let ((ctx (pairy--build-context 2)))
      (should (string-match-p "^File:" ctx))
      (should (string-match-p "Lines" ctx)))))

;; ─── renderer (overlays) ─────────────────────────────────────────────────

(ert-deftest pairy-renderer/show-pending-creates-overlay ()
  "show-pending creates an overlay for the given line."
  (with-temp-buffer
    (insert "# pair: question\n")
    (pairy--show-pending 1)
    (should (gethash 1 pairy--overlays))
    (should (overlayp (gethash 1 pairy--overlays)))))

(ert-deftest pairy-renderer/show-pending-no-duplicate-overlay ()
  "Calling show-pending twice on the same line reuses the overlay (regression)."
  (with-temp-buffer
    (insert "# pair: question\n")
    (pairy--show-pending 1)
    (pairy--show-pending 1)
    (let ((overlays (overlays-in (point-min) (point-max))))
      (should (= (length (seq-filter (lambda (ov) (overlay-get ov 'pairy)) overlays)) 1)))))

(ert-deftest pairy-renderer/append-token-accumulates ()
  "append-token builds up the response string."
  (with-temp-buffer
    (insert "# pair: question\n")
    (pairy--show-pending 1)
    (pairy--append-token 1 "Hello")
    (pairy--append-token 1 " world")
    (should (equal (gethash 1 pairy--responses) "Hello world"))))

(ert-deftest pairy-renderer/finalize-sets-text ()
  "finalize stores the complete response text."
  (with-temp-buffer
    (insert "# pair: question\n")
    (pairy--show-pending 1)
    (pairy--finalize 1 "Final answer.")
    (should (equal (gethash 1 pairy--responses) "Final answer."))))

(ert-deftest pairy-renderer/clear-line-removes-overlay ()
  "clear-line removes the overlay and response for that line."
  (with-temp-buffer
    (insert "# pair: question\n")
    (pairy--show-pending 1)
    (pairy--clear-line 1)
    (should-not (gethash 1 pairy--overlays))
    (should-not (gethash 1 pairy--responses))))

(ert-deftest pairy-renderer/clear-all-removes-everything ()
  "clear-all removes all overlays and responses in the buffer."
  (with-temp-buffer
    (insert "# pair: q1\n# pair: q2\n# pair: q3\n")
    (pairy--show-pending 1)
    (pairy--show-pending 2)
    (pairy--show-pending 3)
    (pairy--clear-all)
    (should (= (hash-table-count pairy--overlays) 0))
    (should (= (hash-table-count pairy--responses) 0))
    (should (null (seq-filter (lambda (ov) (overlay-get ov 'pairy))
                              (overlays-in (point-min) (point-max)))))))

(ert-deftest pairy-renderer/show-error-creates-overlay ()
  "show-error creates an overlay with the error message."
  (with-temp-buffer
    (insert "# pair: question\n")
    (pairy--show-error 1 "API key invalid")
    (let ((ov (gethash 1 pairy--overlays)))
      (should (overlayp ov))
      (should (string-match-p "API key invalid"
                              (overlay-get ov 'after-string))))))

;; ─── pairy--build-body ───────────────────────────────────────────────────

(ert-deftest pairy-build-body/contains-system-prompt ()
  "Request body includes the system instruction."
  (let ((body (pairy--build-body "question?" "context")))
    (should (string-match-p "system_instruction" body))
    (should (string-match-p "pair programmer" body))))

(ert-deftest pairy-build-body/contains-question ()
  "Request body embeds the question in the user content."
  (let ((body (pairy--build-body "is this right?" "some context")))
    (should (string-match-p "is this right?" body))
    (should (string-match-p "some context" body))))

(ert-deftest pairy-build-body/contains-generation-config ()
  "Request body includes generationConfig with maxOutputTokens."
  (let ((body (pairy--build-body "q?" "ctx")))
    (should (string-match-p "generationConfig" body))
    (should (string-match-p "maxOutputTokens" body))))

;; ─── pairy-yank ──────────────────────────────────────────────────────────────

(ert-deftest pairy-yank/copies-response-to-kill-ring ()
  "pairy-yank copies the finalized response text to the kill ring."
  (with-temp-buffer
    (insert "# pair: is this right?\n")
    (goto-char (point-min))
    (pairy--show-pending 1)
    (pairy--finalize 1 "Yes, that's correct.")
    (pairy-yank)
    (should (equal (car kill-ring) "Yes, that's correct."))))

(ert-deftest pairy-yank/no-pair-comment-signals-error ()
  "pairy-yank signals user-error when no pair: comment is near point."
  (with-temp-buffer
    (insert "x = 1\ny = 2\n")
    (goto-char (point-min))
    (should-error (pairy-yank) :type 'user-error)))

(ert-deftest pairy-yank/no-response-signals-error ()
  "pairy-yank signals user-error when no response has been stored yet."
  (with-temp-buffer
    (insert "# pair: unanswered question\n")
    (goto-char (point-min))
    (pairy--ensure-state)
    ;; No response stored — hash table is empty
    (should-error (pairy-yank) :type 'user-error)))

;; ─── pairy-toggle ────────────────────────────────────────────────────────────

(ert-deftest pairy-toggle/hides-overlays-keeps-responses ()
  "pairy-toggle hides overlays without discarding the response data."
  (with-temp-buffer
    (insert "# pair: question\n")
    (pairy--show-pending 1)
    (pairy--finalize 1 "The answer.")
    (pairy-toggle)   ; hide
    (should pairy--hidden)
    (should (= (length (seq-filter (lambda (ov) (overlay-get ov 'pairy))
                                   (overlays-in (point-min) (point-max))))
               0))
    ;; Response data must survive
    (should (equal (gethash 1 pairy--responses) "The answer."))))

(ert-deftest pairy-toggle/restores-overlays-when-shown ()
  "pairy-toggle re-creates overlays when toggled back to visible."
  (with-temp-buffer
    (insert "# pair: question\n")
    (pairy--show-pending 1)
    (pairy--finalize 1 "The answer.")
    (pairy-toggle)   ; hide
    (pairy-toggle)   ; show
    (should-not pairy--hidden)
    (should (overlayp (gethash 1 pairy--overlays)))))

(ert-deftest pairy-toggle/double-toggle-restores-count ()
  "Toggling twice leaves the same number of overlays as before."
  (with-temp-buffer
    (insert "# pair: question\n")
    (pairy--show-pending 1)
    (pairy--finalize 1 "The answer.")
    (let ((before (length (seq-filter (lambda (ov) (overlay-get ov 'pairy))
                                      (overlays-in (point-min) (point-max))))))
      (pairy-toggle)
      (pairy-toggle)
      (let ((after (length (seq-filter (lambda (ov) (overlay-get ov 'pairy))
                                       (overlays-in (point-min) (point-max))))))
        (should (= before after))))))

;; ─── pairy-inspect ───────────────────────────────────────────────────────────

(ert-deftest pairy-inspect/no-api-key-signals-error ()
  "pairy-inspect signals user-error when the API key is not configured."
  (with-temp-buffer
    (insert "hello world\n")
    (goto-char (point-min))
    (setq pairy--config (list :api-key "" :model "gemini-2.5-flash"
                               :context-lines 20 :max-tokens 8192))
    (should-error (pairy-inspect) :type 'user-error)))

(ert-deftest pairy-inspect/no-symbol-at-point-signals-error ()
  "pairy-inspect signals user-error when point is not on a symbol."
  (with-temp-buffer
    (insert "   \n")
    (goto-char (point-min))
    (setq pairy--config (list :api-key "test-key" :model "gemini-2.5-flash"
                               :context-lines 20 :max-tokens 8192))
    (should-error (pairy-inspect) :type 'user-error)))

(ert-deftest pairy-build-body/accepts-custom-system-prompt ()
  "pairy--build-body uses the custom system prompt when provided."
  (let ((body (pairy--build-body "q?" "ctx" "custom system prompt")))
    (should     (string-match-p "custom system prompt" body))
    (should-not (string-match-p "pair programmer" body))))

;;; pairy-test.el ends here
