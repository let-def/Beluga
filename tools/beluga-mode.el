;;; beluga-mode.el --- Major mode for Beluga source code  -*- coding: utf-8; lexical-binding:t -*-

;; Copyright (C) 2009, 2010, 2012, 2013, 2014  Free Software Foundation, Inc.

;; Author: Stefan Monnier <monnier@iro.umontreal.ca>
;; Keywords:

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; BUGS

;; - Indentation thinks "." can only be the termination marker of
;;   an LF declaration.  This can mess things up badly.
;; - Indentation after curried terms like "fn x => fn y =>" is twice that
;;   after "fn x y =>".

;;; Code:

(eval-when-compile (require 'cl))
(require 'smie nil t)                   ;Use smie when available.

(provide 'beluga-unicode-input-method)
(require 'quail)

(defconst beluga-input-method-name "beluga-unicode"
  "The name of the Beluga unicode input method.")

(quail-define-package
 beluga-input-method-name ;; name
 "UTF-8" ;; language
 "\\" ;; title
 t ;; guidance
 "Beluga unicode input method: actually replaces keyword strings with a single unicode character instead of merely representing the keywords in unicode using Font Lock mode."
  nil nil nil nil nil nil nil nil nil nil t)


(quail-define-rules
 ;; Greek letters
 ("\\alpha" ["α"])
 ("\\Alpha" ["Α"])
 ("\\beta" ["β"])
 ("\\Beta" ["Β"])
 ("\\gamma" ["γ"])
 ("\\Gamma" ["Γ"])
 ("\\delta" ["δ"])
 ("\\Delta" ["Δ"])
 ("\\epsilon" ["ε"])
 ("\\Epsilon" ["Ε"])
 ("\\zeta" ["ζ"])
 ("\\Zeta" ["Ζ"])
 ("\\eta" ["η"])
 ("\\Eta" ["Η"])
 ("\\theta" ["θ"])
 ("\\Theta" ["Θ"])
 ("\\iota" ["ι"])
 ("\\Iota" ["Ι"])
 ("\\kappa" ["κ"])
 ("\\Kappa" ["Κ"])
 ("\\lambda" ["λ"])
 ("\\Lambda" ["Λ"])
 ("\\lamda" ["λ"])
 ("\\Lamda" ["Λ"])
 ("\\mu" ["μ"])
 ("\\Mu" ["Μ"])
 ("\\nu" ["ν"])
 ("\\Nu" ["Ν"])
 ("\\xi" ["ξ"])
 ("\\Xi" ["Ξ"])
 ("\\omicron" ["ο"])
 ("\\Omicron" ["Ο"])
 ("\\pi" ["π"])
 ("\\Pi" ["Π"])
 ("\\rho" ["ρ"])
 ("\\Rho" ["Ρ"])
 ("\\sigma" ["σ"])
 ("\\Sigma" ["Σ"])
 ("\\tau" ["τ"])
 ("\\Tau" ["Τ"])
 ("\\upsilon" ["υ"])
 ("\\Upsilon" ["Υ"])
 ("\\phi" ["φ"])
 ("\\Phi" ["Φ"])
 ("\\chi" ["χ"])
 ("\\Chi" ["Χ"])
 ("\\psi" ["ψ"])
 ("\\Psi" ["Ψ"])
 ("\\omega" ["ω"])
 ("\\Omega" ["Ω"])


 ;; Arrows
 ("->" ["→"])
 ("<-" ["←"])
 ("=>" ["⇒"])

 ;;LF
 ("|-" ["⊢"])
 ("\\not" ["¬"])
 ("::" ["∷"])
 ("FN" ["Λ"])
)

(defgroup beluga-mode ()
  "Editing support for the Beluga language."
  :group 'languages)

(defvar beluga-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map "\C-c\C-c" 'compile)
    (define-key map "\C-c\C-l" 'beluga-highlight-holes)
    (define-key map "\C-c\C-e" 'beluga-erase-holes)
    (define-key map "\C-c\C-x" 'beli-cmd)
    (define-key map "\C-c\C-t" 'beli--type)
    (define-key map "\C-c\C-s" 'beluga-split-hole)
    (define-key map "\C-c\C-i" 'beluga-intro-hole)
    (define-key map "\C-c\C-j" 'hole-jump)
    map))

(defvar beluga-mode-syntax-table
  (let ((st (make-syntax-table)))
    (modify-syntax-entry ?% "< 14" st)
    (modify-syntax-entry ?\{ "(}2 b" st)
    (modify-syntax-entry ?\} "){3 b" st)
    (modify-syntax-entry ?\n ">" st)
    ;; For application of dependent arguments "exp A < ctx . term >", we'd want
    ;; <..> to match, but that breaks ->, <-, and other things.
    ;; (modify-syntax-entry ?< "(>" st)
    ;; (modify-syntax-entry ?> ")<" st)
    (modify-syntax-entry ?#  "'" st)
    (modify-syntax-entry ?< "." st)
    (modify-syntax-entry ?> "." st)
    (modify-syntax-entry ?- "." st)
    (modify-syntax-entry ?| "." st)
    (modify-syntax-entry ?= "." st)
    (modify-syntax-entry ?\' "_" st)
    st))

(defcustom beluga-font-lock-symbols
  (not (fboundp 'prettify-symbols-mode))
  "Display |- and -> and such using symbols in fonts.
This may sound like a neat trick, but be extra careful: it changes the
alignment and can thus lead to nasty surprises w.r.t layout."
  :type 'boolean)
(when (fboundp 'prettify-symbols-mode)
  (make-obsolete-variable 'beluga-font-lock-symbols
                          'prettify-symbols-mode "Emacs-24.4"))

(defconst beluga-font-lock-symbols-alist
  ;; Not sure about fn → λ, since we could also have \ → λ.
  '(("not"   . ?¬)
    ;; ("fn"    . ?λ)
    ("FN"    . ?Λ)
    ("|-"    . ?⊢)
    ("psi"   . ?ψ)
    ("phi"   . ?φ)
    ("gamma" . ?γ)
    ("sigma" . ?σ)
    ("#S"    . ?σ)
    ("#S[^]" . ?σ)
    ("#R"    . ?ρ)
    ("#R[^]" . ?ρ)
    ("omega" . ?ω)
    ("Sigma" . ?Σ)
    ("->"    . ?→)
    ("<-"    . ?←)
    ("=>"    . ?⇒)
    ;; ("::"    . ?∷)
    (".." . ?…) ; Actually "..."
    ;;(".."    . ?‥)
    ;; ("forall" . ?∀)
    )
  "Alist mapping Beluga symbols to chars.
Each element has the form (STRING . CHAR) or (STRING CHAR PREDICATE).
STRING is the Beluga symbol.
CHAR is the character with which to represent this symbol.
PREDICATE if present is a function of one argument (the start position
of the symbol) which should return non-nil if this mapping should be disabled
at that position.")

(defun proc-live (process)
  "Returns non-nil if PROCESS is alive.
    A process is considered alive if its status is `run', `open',
    `listen', `connect' or `stop'."
  (memq (process-status process)
        '(run open listen connect stop)))

(defun beluga-font-lock-compose-symbol (alist)
  "Compose a sequence of ascii chars into a symbol.
Regexp match data 0 points to the chars."
  ;; Check that the chars should really be composed into a symbol.
  (let* ((start (match-beginning 0))
         (end (match-end 0))
	 (syntaxes (cond
                    ((eq (char-syntax (char-after start)) ?w) '(?w))
                    ;; Special case for the . used for qualified names.
                    ((and (eq (char-after start) ?\.) (= end (1+ start)))
                     '(?_ ?\\ ?w))
                    (t '(?_ ?\\))))
         sym-data)
    (if (or (memq (char-syntax (or (char-before start) ?\ )) syntaxes)
	    (memq (char-syntax (or (char-after end) ?\ )) syntaxes)
	    (memq (get-text-property start 'face)
		  '(font-lock-doc-face font-lock-string-face
		    font-lock-comment-face))
            (and (consp (setq sym-data (cdr (assoc (match-string 0) alist))))
                 (let ((pred (cadr sym-data)))
                   (setq sym-data (car sym-data))
                   (funcall pred start))))
	;; No composition for you.  Let's actually remove any composition
	;; we may have added earlier and which is now incorrect.
	(remove-text-properties start end '(composition))
      ;; That's a symbol alright, so add the composition.
      (compose-region start end sym-data)))
  ;; Return nil because we're not adding any face property.
  nil)

(defun beluga-font-lock-symbols-keywords ()
  (when (and (fboundp 'compose-region) beluga-font-lock-symbols)
    (let ((alist nil))
      (dolist (x beluga-font-lock-symbols-alist)
	(when (and (if (fboundp 'char-displayable-p)
		       (char-displayable-p (if (consp (cdr x)) (cadr x) (cdr x)))
		     t)
		   (not (assoc (car x) alist)))	;Not yet in alist.
	  (push x alist)))
      (when alist
	`((,(regexp-opt (mapcar 'car alist) t)
	   (0 (beluga-font-lock-compose-symbol ',alist)
              ;; In Emacs-21, if the `override' field is nil, the face
              ;; expressions is only evaluated if the text has currently
              ;; no face.  So force evaluation by using `keep'.
              keep)))))))

(defvar beluga-imenu-generic-expression
  `(("Schemas"
     ,(concat "^[ \t]*schema[ \t\n]+\\(" beluga-syntax-id-re "\\)") 1)
    ("Constructors"
     ,(concat "^\\(" beluga-syntax-id-re "\\)[ \t\n]*:") 1)
    ("Type Constructors"
     ,(concat "^\\(?:inductive[ \t]+\\(" beluga-syntax-id-re
              "\\)\\|\\(?1:" beluga-syntax-id-re
              "\\)[ \t\n]*:[^.]*\\<type\\>[ \t\n]*.\\)") 1)
    ("Functions"
     ,(concat beluga-syntax-fundec-re "[ \t\n]+\\(" beluga-syntax-id-re "\\)") 1)))

(define-obsolete-variable-alias 'beluga-interpreter-path
  ;; A "path" is a list of file names, as in $PATH, $MANPATH.
  'beluga-interpreter-name "Sep-2010")
(defcustom beluga-interpreter-name "beluga"
  "Name of the interpreter executable."
  :type 'string)

;;---------------------------- Interactive mode ----------------------------;;

(defvar beluga--proc ()
  "Contain the process running beli.")
(make-variable-buffer-local 'beluga--proc)

(defun beluga--proc ()
(unless (proc-live beluga--proc) (beluga--start))
;;  (beluga--start)
  beluga--proc)

;; (defun beluga-buffer ()
;;   (process-buffer (beluga--proc)))

(defun beluga--start ()
  "Start an inferior beli process with the -emacs option.
The process is put into a buffer called \"*beli*\".
If a previous beli process already exists, kill it first."
  (beluga--stop)
  (setq beluga--proc
        (get-buffer-process
         (make-comint "beluga"
		      beluga-interpreter-name
                      nil "-I" "-emacs" ))))

(defun beluga--stop ()
  "Stop the beli process."
  (when (processp 'beluga--proc)
    (kill-process 'beluga--proc)))

(defun beluga--wait (proc)
  (assert (eq (current-buffer) (process-buffer proc)))
  (while (and (progn
                (goto-char comint-last-input-end)
                (not (re-search-forward ".*;" nil t)))
              (accept-process-output proc 0.025))))

(defun chomp (str)
  "Chomp leading and tailing whitespace from STR."
  (replace-regexp-in-string (rx (or (: bos (* (any " \t\n")))
                                    (: (* (any " \t\n")) eos)))
                            ""
                            str))
(defun trim (str)
  (let ((str2 (chomp str)))
    (substring str2 0 (1- (length str2)))))

(defun beluga--send (cmd)
  "Send commands to beli."
  ; (interactive)
  (let ((proc (beluga--proc)))
    (with-current-buffer (process-buffer proc)
      (beluga--wait proc)
      ;; We could also just use `process-send-string', but then we wouldn't
      ;; have the input text in the buffer to separate the various prompts.
      (goto-char (point-max))
      (insert (concat "%:" cmd))
      (comint-send-input))))

(defun beluga--receive ()
  "Reads the last output of beli."
  (let ((proc (beluga--proc)))
    (with-current-buffer (process-buffer proc)
      (beluga--wait proc)
      (trim (buffer-substring-no-properties comint-last-input-end (point-max))))))

(defun beluga--rpc (cmd)
  (beluga--send cmd)
  (beluga--receive))

(defun beli--type ()
  "Get the type at the current cursor position (if it exists)"
  (interactive)
  (message "%s" (beluga--rpc (format "get-type %d %d" (count-lines 1 (point)) (current-column)))))

(defun beluga--is-response-error (resp)
  "Determines whether a Beluga RPC response is an error."
  (string= "-" (substring resp 0 1)))

(defun beli ()
  "Start beli mode"
  (interactive)
  (beluga--start))

(defun beli-cmd (cmd)
  "Run a command in beli"
  (interactive "MCommand: ")
  (message "%s" (beluga--rpc cmd)))

(defun maybe-save ()
  (if (buffer-modified-p)
    (if (y-or-n-p "Save current file?")
      (save-buffer)
      ())))

(defun beluga-load ()
  "Loads the current file in beli."
  (interactive)
  (beluga--start)
  (maybe-save)
  (message "%s" (beluga--rpc (concat "load " buffer-file-name))))

(defvar beluga--holes-overlays ()
  "Will contain the list of hole overlays so that they can be resetted.")
(make-variable-buffer-local 'beluga--holes-overlays)

(defun beluga-sorted-holes ()
  (defun hole-comp (a b)
     (let* ((s1 (overlay-start a))
            (s2 (overlay-start b)))
       (< s1 s2)))
  (sort beluga--holes-overlays `hole-comp))



(defface beluga-holes
  '((t :background "cyan")) ;; :foreground "white"
  "Face used to highlight holes in Beluga mode.")

(defun beluga--pos (line bol offset)
  ;; According to http://caml.inria.fr/mantis/view.php?id=5159,
  ;; `line' can refer to line numbers in various source files,
  ;; whereas `bol' and `offset' refer to "character" (byte?) positions within
  ;; the actual parsed stream.
  ;; So if there might be #line directives, we need to do:
  ;; (save-excursion
  ;;   (goto-char (point-min))
  ;;   (forward-line (1- line)) ;Lines count from 1 :-(
  ;;   (+ (point) (- offset bol))))
  ;; But as long as we know there's no #line directive, we can ignore all that
  ;; and use the more efficient code below.  When #line directives can appear,
  ;; we will need to make further changes anyway, such as passing the file-name
  ;; to select the appropriate buffer.
  ;; Emacs considers the first character in the file to be at index 1,
  ;; but the Beluga lexer starts counting at zero, so we need to add
  ;; one here.
  (+ (point-min) offset))

(defun beluga--create-overlay (pos)
  "Create an overlay at the position described by POS (a Loc.to_tuple)."
  (let* (;; (file-name (nth 0 pos))
         (start-line (nth 1 pos))
         (start-bol (nth 2 pos))
         (start-off (nth 3 pos))
         (stop-line (nth 4 pos))
         (stop-bol (nth 5 pos))
         (stop-off (nth 6 pos))
         (ol
          (make-overlay (beluga--pos start-line start-bol start-off)
                        (beluga--pos stop-line  stop-bol  stop-off))))
    (overlay-put ol 'face 'beluga-holes)
    ol))

(defun beluga-highlight-holes ()
  "Create overlays for each of the holes and color them."
  (interactive)
  (beluga-load)
  (beluga-erase-holes)
  (let ((numholes (string-to-number (beluga--rpc "numholes"))))
    (dotimes (i numholes)
      (let* ((pos (read (beluga--rpc (format "lochole %d" i))))
             (ol (beluga--create-overlay pos))
             (info (beluga--rpc (format "printhole %d" i))))
        (overlay-put ol 'help-echo info)
        (push ol beluga--holes-overlays)
        )))
  (let ((numholes (string-to-number (beluga--rpc "numlfholes"))))
    (dotimes (i numholes)
      (let* ((pos (read (beluga--rpc (format "lochole-lf %d" i))))
             (ol (beluga--create-overlay pos))
             (info (beluga--rpc (format "printhole-lf %d" i))))
        (overlay-put ol 'help-echo info)
        (push ol beluga--holes-overlays)
        ))))

(defun beluga--lookup-hole (hole)
  "Looks up a hole number by its name"
  (string-to-number (beluga--rpc (format "lookuphole %s" hole))))

(defun beluga--get-hole-overlay (hole)
  "Gets the overlay associated with a hole."
  (nth (beluga--lookup-hole hole) (beluga-sorted-holes)))

(defun insert-formatted (str start)
  (goto-char start)
  (insert (apply-quail-completions str))
  (indent-region start (+ start (length str))))

(defun apply-quail-completions (str)
  (if (string= current-input-method beluga-input-method-name)
     (replace-regexp-in-string "=>" "⇒"
      (replace-regexp-in-string "|-" "⊢" str))
     str))

(defun error-no-such-hole (n)
  (message "Couldn't find hole %s - make sure the file is loaded" n))

(defun beluga-split-hole (hole var)
  "Split on a hole"
  (interactive "sHole to split at: \nsVariable to split on: ")
  (beluga-load)
  (beluga-highlight-holes)
  (let ((resp (beluga--rpc (format "split %s %s" hole var))))
    (if (beluga--is-response-error resp)
      (message "%s" resp)
      (let ((ovr (beluga--get-hole-overlay hole)))
        (if ovr
          (let ((start (overlay-start ovr))
                (end (overlay-end ovr)))
            (delete-overlay ovr)
            (delete-region start end)
            (insert-formatted (format "(%s)" resp) start)
            (save-buffer)
            ; Need to load twice after modifying the file because
            ; positions in Beluga are broken.
            (beluga-load)
            (beluga-highlight-holes))
        (error-no-such-hole hole))))))

(defun beluga-intro-hole (hole)
  "Introduce variables into a hole"
  (interactive "sHole to introduce variables into: ")
  (beluga-load)
  (beluga-highlight-holes)
  (let ((resp (beluga--rpc (format "intro %s" hole))))
    (if (beluga--is-response-error resp)
      (message "%s" resp)
      (let ((ovr (beluga--get-hole-overlay hole)))
        (if ovr
          (let ((start (overlay-start ovr))
                (end (overlay-end ovr)))
            (delete-overlay ovr)
            (delete-region start end)
            (insert-formatted resp start)
            (save-buffer)
            (beluga-load)
            (beluga-highlight-holes))
          (error-no-such-hole hole))))))

(defun hole-jump (hole)
  (interactive "nHole to jump to: ")
  (let ((ovr (nth hole (beluga-sorted-holes))))
    (if ovr
      (goto-char (overlay-start ovr))
      (error-no-such-hole hole))))

(defun beluga-erase-holes ()
  (interactive)
  (mapc #'delete-overlay beluga--holes-overlays)
  (setq beluga--holes-overlays nil))

(defconst beluga-syntax-pragma-re
  "--\\(\\(name\\|query\\).*?\\.\\|\\w+\\)"
  "A regexp for matching a Beluga pragma. Long pragmas continue until a `.` is found, e.g. `--name oft D.`.
Short pragmas consist of only one word, e.g. `--nostrengthen`.")

(defconst beluga-punct-re
  (regexp-opt '("->" "<-" "=>" "\\" "." "<" ">" "," ";" "..")))

(defconst beluga-syntax-id-re
  "[[:alpha:]_][[:alnum:]_']*"
  "A regexp for matching a Beluga identifier.")

(defconst beluga-syntax-fundec-re
  "\\<\\(rec\\|and\\)\\>"
  "A regexp for matching a function declaration.")

(defconst beluga-font-lock-keywords
  `((,beluga-syntax-pragma-re . ,font-lock-warning-face)

    ,(regexp-opt
     '("FN" "and" "block" "case" "inductive" "LF" "coinductive" "stratified" "else" "ffalse" "fn" "if"
       "in" "impossible" "let" "mlam" "of" "rec" "schema" "some"
       "then" "type" "ctype" "ttrue" "module" "struct" "end"
       "#stratified" "#positive" "total" "fun")
     'symbols)

    ,"\\_<\\(total\\)\\_>" . 'italic)

    (,"/\\s-*total.*?/" . (face 'italic))

    (,(concat "^\\(" beluga-syntax-id-re "\\)"
              "\\s-*" ":" "\\([^.]*\\_<type\\_>\\s-*.\\)?")
     ;; This is a regexp that can span multiple lines, so it may not
     ;; always highlight properly.  `font-lock-multiline' tries to help.
     (0 (if (match-end 2) '(face nil font-lock-multiline t)))
     (1 (if (match-end 2)
            font-lock-type-face font-lock-variable-name-face)))

    (,(concat "^\\(?:schema\\|inductive\\|coinductive\\|LF\\|stratified\\)" "\\s-+"
              "\\(" beluga-syntax-id-re "\\)")
     (1 font-lock-type-face))

    (,(concat beluga-syntax-fundec-re "\\s-+\\(" beluga-syntax-id-re "\\)")
     (2 font-lock-function-name-face))
    ))

;;---------------------------- Loading of the mode ----------------------------;;

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.s?bel\\'" . beluga-mode))

(unless (fboundp 'prog-mode)
  (defalias 'prog-mode #'fundamental-mode))

;;;###autoload
(define-derived-mode beluga-mode prog-mode "Beluga"
  "Major mode to edit Beluga source code."
  (set (make-local-variable 'imenu-generic-expression)
       beluga-imenu-generic-expression)
  (set (make-local-variable 'outline-regexp)
       (concat beluga-syntax-fundec-re "\\|^(inductive|coinductive|LF|stratified)\\_>"))
  (set (make-local-variable 'require-final-newline) t)
  (when buffer-file-name
    (set (make-local-variable 'compile-command)
         ;; Quite dubious, but it's the intention that counts.
         (concat beluga-interpreter-name
                 " "
                 (shell-quote-argument buffer-file-name))))
  (set (make-local-variable 'comment-start) "%")
  (set (make-local-variable 'comment-start-skip) "%[%{]*[ \t]*")
  (set (make-local-variable 'comment-end-skip) "[ \t]*\\(?:\n\\|}%\\)")
  (comment-normalize-vars)
  (set (make-local-variable 'electric-indent-chars)
       (append '(?|) (if (boundp 'electric-indent-chars)
                         electric-indent-chars
                       '(?\n))))
  ;QUAIL
  (add-hook 'beluga-mode-hook
   (lambda () (set-input-method "beluga-unicode")))

  ;Turn off hilighting
  (setq input-method-highlight-flag nil)

  (smie-setup
   (with-no-warnings beluga-smie-grammar)
   #'beluga-smie-indent-rules
   :forward-token #'beluga-smie-forward-token
   :backward-token #'beluga-smie-backward-token)

  (set (make-local-variable 'parse-sexp-ignore-comments) t)

  (set
   (make-local-variable 'prettify-symbols-alist)
   beluga-font-lock-symbols-alist)
  (set
   (make-local-variable 'font-lock-defaults)
   '(beluga-font-lock-keywords
     nil
     nil
     ()
     nil
     (font-lock-syntactic-keywords . nil))))

;;; Beluga indentation and navigation via SMIE

(defcustom beluga-indent-basic 4
  "Basic amount of indentation."
  :type 'integer)

(defun beluga-smie-forward-token ()
  (forward-comment (point-max))
  (if (looking-at "\\.[ \t]*$")
      ;; One of the LF-terminating dots.
      (progn (forward-char 1) ";.")
    (buffer-substring-no-properties
     (point)
     (progn (cond
             ((looking-at beluga-punct-re) (goto-char (match-end 0)))
             ((not (zerop (skip-syntax-forward "w_'"))))
             ;; In case of non-ASCII punctuation.
             ((not (zerop (skip-syntax-forward ".")))))
            (point)))))

(defun beluga-smie-backward-token ()
  (forward-comment (- (point-max)))
  (if (and (eq ?\. (char-before))
           (looking-at "[ \t]*$") ;; "[ \t]*\\(?:$\\|[0-9]\\(\\)\\)"
           (not (looking-back "\\.\\." (- (point) 2))))
      ;; Either an LF-terminating dot, or a projection-dot.
      (progn (forward-char -1) ";.") ;; (if (match-end 1) ".n" ";.")
    (buffer-substring-no-properties
     (point)
     (progn (cond
             ((looking-back beluga-punct-re (- (point) 2) 'greedy)
              (goto-char (match-beginning 0)))
             ((not (zerop (skip-syntax-backward "w_'"))))
             ;; In case of non-ASCII punctuation.
             ((not (zerop (skip-syntax-backward ".")))))
            (point)))))

(defun beluga-smie-grammar (bnf resolvers precs)
  (smie-prec2->grammar
   (smie-merge-prec2s
    (apply #'smie-bnf->prec2 bnf resolvers)
    (smie-precs->prec2 precs))))

(defconst beluga-smie-grammar
  ;; The "." used for terminating LF declarations is syntactically completely
  ;; different from the "." used in the binding forms.  Conflating the two
  ;; leads here to a lot of precedence conflicts, so we try and guess the two
  ;; based on a heuristic in the tokenizing code.
  (beluga-smie-grammar
   ;; FIXME: without this dummy, "=>" is marked as "open paren" because it
   ;; can only bind to `atom' on the left.
   '((atom ("--dummy--"))

     (def (exp "=" exp) (atom ":" exp))

     (decl
      (atom ":" type)
      ("inductive" datatype-def)
	    ("coinductive" datatype-def)
	    ("LF" datatype-def)
	    ("stratified" datatype-def)
      ("schema" sdef)
      ("let" def)
      (recs))

     (simpletype
      (simpletype "->" simpletype)
      (simpletype "<-" simpletype))

     (recs
      ("rec" def)
      (recs "and" recs))

     (decls
      (decl)
      (decls ";" decls)
      (decls ";." decls)) ; JJJ is this legal syntax?

     ;; FIXME: only allow simple types here, otherwise we get nasty
     ;; precedence conflicts between "." and ",".  In practice, this seems to
     ;; be sufficient.
     (sdecl
      (atom ":" type)) ; JJJ is the above comment a lie?

     (sdecls
      (sdecl)
      (sdecls "," sdecls))

     (dotted-type
      (sdecls "|-" type))

     (type
      (simpletype)
      ("\\" atom "." type)         ;dotted-type
      ("block" sdecls "." type)    ;dotted-type
      ;; ("{" blabla "}" type)  ; FIXME!
      ;; FIXME: the projection via "." creates precedence conflicts.
      ;; (type "." atom)
      )

     (sdef
      (atom "=" schema))

     (schema
      (type)
      ;; Not sure if it's correct, and create precedence conflicts.
      ;; ("some" sdecls "block" sdecls "." schema)
      )

     (datatype-name
      (atom ":" type))

     (datatype-def
      (datatype-name "=" datatype-branches))

     (datatype-branches
      (datatype-branches "|" datatype-branches)
      (atom ":" type))

     (exp
      ("if" exp "then" exp "else" exp)
      (type)
      ("let" def "in" exp)
      ("fn" atom "=>" exp)
      ("FN" atom "=>" exp)
      ("mlam" atom "=>" exp)
      ("<" dotted-type ">")
      ("case" exp "of" cases))

     (exps
      (exps ";" exps)
      (exp))

     ;; Separate cases/branch so that "|" is recognized as associative.
     (cases
      (branch)
      (cases "|" cases))

     (branch
      (atom "=>" exp)))

   '(((assoc ";" ";."))
     ((assoc "->" "<-"))
     ((assoc ","))
     ((assoc "and"))
     ((nonassoc "of") (assoc "|"))      ; Trailing | ambiguity.
     ;; '((nonassoc "\\") (nonassoc ".")) ; Trailing . ambiguity.
     ;; '((nonassoc "block") (nonassoc ".")) ; Trailing . ambiguity.
     )

   ;; The above BNF grammar should cover this already, so this ends up only
   ;; useful to check that the BNF entails the expected precedences.
   '((assoc ";")
     (assoc ",")
     (left ":")
     (assoc "<-" "->")
     (nonassoc " -dummy- "))))          ;Bogus anchor at the end.

(defun beluga-smie-indent-rules (method token)
  (cond
   ((eq method :list-intro) (member token '("fn" "FN" "mlam")))
   ((and (eq method :elem) (eq token 'arg)) beluga-indent-basic)
   ((and (eq method :before) (equal token "|") (smie-rule-prev-p "=" "of"))
    ;; Presumable a "datatype foo = | ...".
    (smie-rule-parent))
   ((equal token "|") (smie-rule-separator method))
   ((eq method :after)
    (cond
     ((equal token "of") 2)
     ((equal token "in") (if (smie-rule-hanging-p) 0))
     ((equal token "=") 0)
     ;; FIXME: Specify the indentation after => depending
     ;; on whether it is a "=>" that goes with an "fn" or with a "|".
     ((equal token "=>") 0)
     ((member token '(":" "let" "if")) beluga-indent-basic)))
   ((eq method :before)
    (cond
     ((and (equal token "=") (smie-rule-parent-p "inductive")) 2)
     ((member token '("case" "fn" "mlam"))
      (if (smie-rule-prev-p "=>") (smie-rule-parent)))))))

(provide 'beluga-mode)
;;; beluga-mode.el ends here
