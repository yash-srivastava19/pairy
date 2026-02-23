;;; pairy.el --- AI pair programming via inline comments  -*- lexical-binding: t -*-

;; Author: pairy
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: ai, programming, tools
;; URL: https://github.com/yash-srivastava19/pairy

;;; Commentary:
;; Write a `pair:' comment, hit a key, get an AI response as inline
;; overlay text — never written to the file.
;;
;; Quick start:
;;   M-x pairy-init       — create ~/.config/pairy/config.json
;;   M-x pairy-mode       — enable in current buffer
;;   C-c a s              — send pair: comment at point
;;   C-c a c              — clear all responses
;;   C-c a K              — cancel in-flight request
;;
;; Reads the same config file as the Neovim plugin:
;;   ~/.config/pairy/config.json

;;; Code:

(require 'json)
(require 'cl-lib)

;; ─── Faces ────────────────────────────────────────────────────────────────

(defface pairy-pending-face
  '((t :foreground "#666666" :slant italic))
  "Face for pairy thinking/pending indicator.")

(defface pairy-response-face
  '((t :foreground "#888888" :slant italic))
  "Face for pairy response text.")

(defface pairy-marker-face
  '((t :foreground "#888888" :weight bold))
  "Face for the ⬡ marker.")

(defface pairy-error-face
  '((t :foreground "#cc4444" :slant italic))
  "Face for pairy error text.")

;; ─── Config ───────────────────────────────────────────────────────────────
;; Reads the same ~/.config/pairy/config.json as the Neovim plugin.

(defconst pairy--config-path
  (expand-file-name "~/.config/pairy/config.json"))

(defvar pairy--config nil
  "Cached config plist. Cleared by `pairy-reload'.")

(defun pairy--load-config ()
  "Load and cache config from `pairy--config-path'."
  (unless (file-readable-p pairy--config-path)
    (user-error "pairy: no config at %s — run M-x pairy-init" pairy--config-path))
  (with-temp-buffer
    (insert-file-contents pairy--config-path)
    (let ((raw (json-parse-buffer :object-type 'plist :array-type 'array)))
      (setq pairy--config
            (list :api-key       (or (plist-get raw :api_key) "")
                  :model         (or (plist-get raw :model) "gemini-2.5-flash")
                  :context-lines (or (plist-get raw :context_lines) 20)
                  :max-tokens    (or (plist-get raw :max_tokens) 8192))))))

(defun pairy--cfg (key)
  "Get config value for KEY, loading config if needed."
  (unless pairy--config (pairy--load-config))
  (plist-get pairy--config key))

;; ─── System prompt ────────────────────────────────────────────────────────
;; Identical to the Neovim plugin's SYSTEM_PROMPT.

(defconst pairy--system-prompt
  "You are a senior pair programmer. The user has left a `pair:` comment \
with a question or thought. Your job is not just to answer — it is to help \
them think more clearly and write better code.

How to respond:
- If the question reveals an unstated assumption or a gap in thinking, \
surface it first.
- Give a direct opinion when asked. Do not hedge unless the tradeoff \
genuinely depends on context you don't have.
- If they are on the right track, confirm it in one clause and push to \
the next consideration.
- If they are off track, say so directly and redirect.
- Ask one probing question back when it would help them reason through \
the problem.

Constraints:
- 2-5 sentences. Every word earns its place.
- No markdown headers. No bullet lists unless genuinely enumerating \
distinct things.
- No \"great question\", no preamble, no summary at the end.
- Write as if your response will appear as comment lines in the file — \
plain prose, ~80 chars per line.
- Always reference the actual code: use the variable names, function \
names, and patterns visible in the context.")

;; ─── Comment detection ────────────────────────────────────────────────────
;; Same patterns as detector.lua — matches inline and standalone comments.
;; string-match searches anywhere in the string so no ^.- needed.

(defconst pairy--pair-regexp
  "\\(?:--+\\|#+\\|//+\\|/\\*+\\)\\s-*pair:\\s-*\\(.+\\)"
  "Regexp matching a pair: comment. Group 1 is the question text.")

(defun pairy--extract-question (line)
  "Return question text from LINE, or nil if not a pair: comment."
  (when (string-match pairy--pair-regexp line)
    (string-trim (match-string 1 line))))

(defun pairy--line-text (line-nr)
  "Return text content of LINE-NR (1-indexed, no properties)."
  (save-excursion
    (goto-char (point-min))
    (forward-line (1- line-nr))
    (buffer-substring-no-properties (line-beginning-position)
                                    (line-end-position))))

(defun pairy--build-context (line-nr)
  "Build formatted code context block around LINE-NR (1-indexed)."
  (let* ((ctx   (pairy--cfg :context-lines))
         (total (line-number-at-pos (point-max)))
         (start (max 1 (- line-nr ctx)))
         (end   (min total (+ line-nr ctx)))
         (ft    (string-remove-suffix "-mode" (symbol-name major-mode)))
         (fname (if buffer-file-name
                    (file-name-nondirectory buffer-file-name)
                  "[unnamed]"))
         (width (length (number-to-string end)))
         (fmt   (format "%%s %%%dd: %%s" width))
         lines)
    (save-excursion
      (goto-char (point-min))
      (forward-line (1- start))
      (cl-loop for n from start to end do
               (push (format fmt
                             (if (= n line-nr) ">" " ")
                             n
                             (buffer-substring-no-properties
                              (line-beginning-position) (line-end-position)))
                     lines)
               (forward-line 1)))
    (concat (format "File: %s (%s)\nLines %d-%d:\n" fname ft start end)
            "```" ft "\n"
            (mapconcat #'identity (nreverse lines) "\n") "\n"
            "```")))

(defun pairy--find-at-point ()
  "Find pair: comment at or up to 3 lines above point.
Returns (LINE-NR QUESTION CONTEXT) or nil."
  (let ((cur (line-number-at-pos)))
    (cl-loop for offset from 0 to 3
             for line-nr = (- cur offset)
             when (> line-nr 0)
             do (let ((q (pairy--extract-question (pairy--line-text line-nr))))
                  (when q
                    (cl-return (list line-nr q (pairy--build-context line-nr)))))
             finally return nil)))

;; ─── Renderer (overlays) ──────────────────────────────────────────────────
;; Overlays with `after-string' starting with \n render below the line —
;; the Emacs equivalent of Neovim's virt_lines.

(defvar-local pairy--overlays  nil
  "Hash table: line-nr → overlay. Initialized lazily per buffer.")
(defvar-local pairy--responses nil
  "Hash table: line-nr → accumulated response string. Initialized lazily per buffer.")

(defun pairy--ensure-state ()
  "Initialize buffer-local hash tables if not yet done for this buffer."
  (unless pairy--overlays
    (setq pairy--overlays  (make-hash-table :test 'eql)))
  (unless pairy--responses
    (setq pairy--responses (make-hash-table :test 'eql))))

(defun pairy--line-end-pos (line-nr)
  "Buffer position at end of LINE-NR (1-indexed)."
  (save-excursion
    (goto-char (point-min))
    (forward-line (1- line-nr))
    (line-end-position)))

(defun pairy--get-indent (line-nr)
  "Leading whitespace of LINE-NR as a string."
  (let ((text (pairy--line-text line-nr)))
    (if (string-match "^\\(\\s-*\\)" text)
        (match-string 1 text)
      "")))

(defun pairy--set-overlay (line-nr text face)
  "Create or update the overlay for LINE-NR, showing TEXT with FACE."
  (pairy--ensure-state)
  (let* ((pos     (pairy--line-end-pos line-nr))
         (indent  (pairy--get-indent line-nr))
         (display (concat "\n" indent
                          (propertize "⬡ " 'face 'pairy-marker-face)
                          (propertize text  'face face)))
         (ov      (gethash line-nr pairy--overlays)))
    (unless ov
      (setq ov (make-overlay pos pos nil t nil))
      (overlay-put ov 'pairy t)
      (puthash line-nr ov pairy--overlays))
    (overlay-put ov 'after-string display)))

(defun pairy--show-pending (line-nr &optional phase)
  "Show pending indicator for LINE-NR."
  (pairy--ensure-state)
  (pairy--set-overlay line-nr (or phase "thinking...") 'pairy-pending-face)
  (puthash line-nr "" pairy--responses))

(defun pairy--append-token (line-nr token)
  "Append TOKEN to streaming response for LINE-NR."
  (let ((acc (concat (gethash line-nr pairy--responses "") token)))
    (puthash line-nr acc pairy--responses)
    (pairy--set-overlay line-nr acc 'pairy-response-face)))

(defun pairy--finalize (line-nr text)
  "Set final response TEXT for LINE-NR."
  (puthash line-nr text pairy--responses)
  (pairy--set-overlay line-nr text 'pairy-response-face))

(defun pairy--show-error (line-nr msg)
  "Show error MSG for LINE-NR."
  (pairy--set-overlay line-nr msg 'pairy-error-face))

(defun pairy--clear-line (line-nr)
  "Remove overlay and response for LINE-NR."
  (when-let ((ov (gethash line-nr pairy--overlays)))
    (delete-overlay ov)
    (remhash line-nr pairy--overlays))
  (remhash line-nr pairy--responses))

(defun pairy--clear-all ()
  "Remove all pairy overlays in current buffer."
  (remove-overlays (point-min) (point-max) 'pairy t)
  (when pairy--overlays  (clrhash pairy--overlays))
  (when pairy--responses (clrhash pairy--responses)))

;; ─── API client ───────────────────────────────────────────────────────────
;; Same curl command and SSE parsing as client.lua.

(defvar-local pairy--active-process nil
  "Active curl process, or nil.")

(defun pairy--parse-sse-line (line)
  "Parse one SSE LINE from Gemini's stream.
Returns delta text string, \"__ERROR__:msg\", or nil (ignore)."
  (setq line (string-trim line))
  (cond
   ((string= line "")                    nil)
   ((string-prefix-p "event:" line)      nil)
   ((string-prefix-p ":" line)           nil)
   ((not (string-prefix-p "data:" line)) nil)
   (t
    (let ((payload (string-trim (substring line 5))))
      (condition-case nil
          (let* ((parsed (json-parse-string payload :object-type 'plist :array-type 'array))
                 (err    (and (listp parsed) (plist-get parsed :error))))
            (cond
             ;; API error object
             (err (concat "__ERROR__:"
                          (or (plist-get err :message) "unknown API error")))
             ;; Happy path: candidates[0].content.parts[0].text
             ((listp parsed)
              (condition-case nil
                  (let* ((cands (plist-get parsed :candidates))
                         (c0    (and (vectorp cands) (aref cands 0)))
                         (parts (and c0 (plist-get (plist-get c0 :content) :parts)))
                         (text  (and (vectorp parts)
                                     (plist-get (aref parts 0) :text))))
                    (and (stringp text) text))
                (error nil)))
             (t nil)))
        (error nil))))))

(defun pairy--build-url ()
  "Gemini streaming SSE endpoint URL."
  (format
   "https://generativelanguage.googleapis.com/v1beta/models/%s:streamGenerateContent?alt=sse&key=%s"
   (pairy--cfg :model)
   (pairy--cfg :api-key)))

(defun pairy--build-body (question context)
  "JSON request body for QUESTION with CONTEXT."
  (json-encode
   `((system_instruction . ((parts . [((text . ,pairy--system-prompt))])))
     (contents . [((role  . "user")
                   (parts . [((text . ,(concat context
                                               "\n\nQuestion: "
                                               question)))]))])
     (generationConfig . ((maxOutputTokens . ,(pairy--cfg :max-tokens)))))))

(defun pairy--do-send (line-nr question context on-token on-done on-error)
  "Launch curl subprocess for QUESTION+CONTEXT, streaming into callbacks.
Returns the process object."
  (unless (executable-find "curl")
    (funcall on-error "curl not found in PATH")
    (cl-return-from pairy--do-send nil))
  (let* ((body    (pairy--build-body question context))
         (tmp     (make-temp-file "pairy-" nil ".json" body))
         (buf     (current-buffer))
         (linebuf (list ""))          ; partial SSE line accumulator
         (acc     (list ""))          ; full response accumulator
         (done    (list nil)))        ; fired on-done/on-error flag
    (cl-labels
        ((handle-line (line)
           (unless (car done)
             (let ((result (pairy--parse-sse-line line)))
               (cond
                ((null result) nil)
                ((string-prefix-p "__ERROR__:" result)
                 (setcar done t)
                 (with-current-buffer buf
                   (funcall on-error (substring result 10))))
                (t
                 (setcar acc (concat (car acc) result))
                 (with-current-buffer buf
                   (funcall on-token result)))))))
         (handle-chunk (_proc chunk)
           (setcar linebuf (concat (car linebuf) chunk))
           (let ((parts (split-string (car linebuf) "\n")))
             (setcar linebuf (car (last parts)))
             (mapc #'handle-line (butlast parts))))
         (handle-exit (_proc event)
           (delete-file tmp)
           (unless (car done)
             (when (and (car linebuf) (not (string= (car linebuf) "")))
               (handle-line (car linebuf)))
             (with-current-buffer buf
               (if (string-prefix-p "finished" event)
                   (if (not (string= (car acc) ""))
                       (funcall on-done (car acc))
                     (funcall on-error "Empty response from API"))
                 (funcall on-error
                          (format "curl error: %s" (string-trim event))))))))
      (make-process
       :name     "pairy-curl"
       :buffer   nil
       :command  (list "curl" "--silent" "--no-buffer" "--http1.1"
                       "-X" "POST"
                       "-H" "content-type: application/json"
                       "--data-binary" (concat "@" tmp)
                       (pairy--build-url))
       :filter   #'handle-chunk
       :sentinel #'handle-exit))))

;; ─── Public commands ──────────────────────────────────────────────────────

;;;###autoload
(defun pairy-send ()
  "Send the pair: comment at or near point to the AI."
  (interactive)
  (when (or (null (pairy--cfg :api-key))
            (string= (pairy--cfg :api-key) ""))
    (user-error "pairy: no API key — run M-x pairy-init"))
  (let ((found (pairy--find-at-point)))
    (unless found
      (user-error "pairy: no pair: comment found at or above point"))
    (cl-destructuring-bind (line-nr question context) found
      (when pairy--active-process
        (delete-process pairy--active-process))
      (pairy--show-pending line-nr)
      (setq pairy--active-process
            (pairy--do-send
             line-nr question context
             (lambda (token) (pairy--append-token line-nr token))
             (lambda (text)  (pairy--finalize     line-nr text))
             (lambda (msg)
               (pairy--show-error line-nr msg)
               (message "pairy error: %s" msg)))))))

;;;###autoload
(defun pairy-clear ()
  "Clear all pairy responses in the current buffer."
  (interactive)
  (pairy--clear-all)
  (message "pairy: cleared"))

;;;###autoload
(defun pairy-clear-line ()
  "Clear pairy response at the current line."
  (interactive)
  (pairy--clear-line (line-number-at-pos))
  (message "pairy: cleared line"))

;;;###autoload
(defun pairy-cancel ()
  "Cancel the active pairy request."
  (interactive)
  (when pairy--active-process
    (delete-process pairy--active-process)
    (setq pairy--active-process nil)
    (message "pairy: cancelled")))

;;;###autoload
(defun pairy-reload ()
  "Reload config from disk."
  (interactive)
  (setq pairy--config nil)
  (pairy--load-config)
  (message "pairy: config reloaded"))

;;;###autoload
(defun pairy-init ()
  "Create ~/.config/pairy/config.json from template and open it."
  (interactive)
  (if (file-exists-p pairy--config-path)
      (message "pairy: config already exists at %s" pairy--config-path)
    (make-directory (file-name-directory pairy--config-path) t)
    (write-region
     (concat "{\n"
             "  \"api_key\": \"YOUR_GEMINI_API_KEY\",\n"
             "  \"model\": \"gemini-2.5-flash\",\n"
             "  \"context_lines\": 20,\n"
             "  \"max_tokens\": 8192\n"
             "}\n")
     nil pairy--config-path)
    (message "pairy: created %s — add your API key and save" pairy--config-path)
    (find-file pairy--config-path)))

;; ─── Minor mode ───────────────────────────────────────────────────────────

(defvar pairy-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c a s") #'pairy-send)
    (define-key map (kbd "C-c a c") #'pairy-clear)
    (define-key map (kbd "C-c a x") #'pairy-clear-line)
    (define-key map (kbd "C-c a K") #'pairy-cancel)
    map)
  "Keymap for `pairy-mode'.")

;;;###autoload
(define-minor-mode pairy-mode
  "AI pair programming via inline pair: comments.
\\{pairy-mode-map}"
  :lighter " ⬡"
  :keymap pairy-mode-map)

;;;###autoload
(define-globalized-minor-mode global-pairy-mode pairy-mode
  (lambda () (pairy-mode 1)))

(provide 'pairy)
;;; pairy.el ends here
