;;; texpresso-view.el --- TeXpresso's live view inside Emacs  -*- lexical-binding: t -*-

;; Author: Stefano Coniglio
;; URL: https://github.com/stefanoconiglio/emacs-texpresso-view
;; Version: 0.1
;; Package-Requires: ((emacs "29.1") (texpresso "0"))
;; Keywords: tex
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This program is free software: you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by the Free
;; Software Foundation, either version 3 of the License, or (at your option)
;; any later version.  See the file LICENSE.

;;; Commentary:

;; TeXpresso (https://github.com/let-def/texpresso) re-typesets a LaTeX
;; document as you type and shows its pages in a window of its own.  This
;; package shows them inside Emacs instead, in the window to the right of the
;; source, the way pdf-tools shows a PDF: TeXpresso renders the page on
;; display as a PNG, Emacs displays it.  No PDF is made: TeXpresso draws
;; XeTeX's page descriptions directly, which is why it is fast.
;;
;; M-x texpresso-view in a LaTeX buffer: TeXpresso on that file, with no window
;; of its own, and its page on the right, following the cursor and updating
;; as you type.  Run it again to close it.  With a prefix argument (C-u), it
;; typesets AUCTeX's `TeX-master', the whole document the file is part of,
;; and the page follows that file the same way.  In the page's window: a click
;; jumps to the source line under it (or says there is none); a drag copies
;; the text it crosses, highlighted on the page; n / p (or PageDown / PageUp,
;; the arrows, SPC / DEL, the mouse wheel) turn the pages; q closes the
;; window.  A click also selects the page's window, so its keys work at
;; once.  The page fits its window, in the colours of the Emacs theme (a
;; terminal's own when Emacs has none there), and follows a theme switched.
;;
;; Scroll sync, both ways: a page turned brings its source to the top of the
;; source window (a beamer frame's \begin{frame}, in whichever file it is); a
;; scroll of the source brings the page of the line at its top.  Moving the
;; cursor brings the cursor's page, as `texpresso-follow-cursor' does.
;;
;; Errors: when the text stops TeX (a brace left open to the end of the
;; file, a missing \end{document}), a red line over the page says so and
;; why, until the text is mended; other errors are counted in the page
;; window's mode line.
;;
;; In a text terminal (`emacs -nw', `emacsclient -t'), in one that draws
;; Sixel pictures (foot, WezTerm, Konsole, xterm -ti vt340…), the page is a
;; Sixel picture drawn over its window, which Emacs leaves blank, the
;; window's size after a zoom too; clicks and drags work with
;; `xterm-mouse-mode'.  A text terminal without Sixel gets
;; an error.  Where Emacs has no theme there, the page takes the terminal's
;; colours, and follows them when the terminal is recoloured from outside
;; (a desktop theme switch), once it has the focus again.
;;
;; Slides with the mouse, as in Google Slides: in the page's window, i puts
;; a picture on the slide where you last clicked (C-y the clipboard's, or
;; drop a file), t a text box; a click selects an object, a drag moves it,
;; a corner resizes it, and the source follows as it moves (one undo).  The
;; arrows nudge it, + and - resize it, d copies it, DEL deletes it, RET
;; shows it in the source, ] and [ bring it forward and back.  An object is
;; a TikZ node in the frame's tvlayer, placed from the slide's top left
;; corner in hundredths of its width: plain LaTeX, defined once before
;; \begin{document}.  s opens the slide strip on the left
;; (`texpresso-view-slides'): every frame with a small picture of its page
;; and its title, to show, move (M-up, M-down or a drag), copy, delete and
;; add from a layout (`texpresso-view-layouts').
;;
;; Edits made on disk by another program (a script, an AI agent) show too:
;; to a file open in Emacs once it is reverted (`auto-revert-mode',
;; `global-auto-revert-mode'), to one not open as soon as it is written, if
;; it is in the document's folder or below.
;;
;; Texinfo: in a .texi file, the manual is typeset with plain XeTeX's
;; format, which texinfo.tex is written for (TeXpresso's patch 0016), and
;; edits to it and to the files it @includes reach the page as LaTeX's do.
;; Its index stays empty: texindex is not run.
;;
;; It needs a TeXpresso with the commands `render-to', `click-at' and
;; `select' (and its rerun fixes): until they are upstream, TeXpresso built
;; with the patches in the folder texpresso/ of this package's repository.

;;; Code:

(require 'texpresso)
(require 'subr-x)
(require 'filenotify)
(require 'svg)
(require 'dnd)

(defconst texpresso-view-buffer-name "*TeXpresso window*"
  "Name of the buffer showing the page.
texpresso.el knows it: a click answered while it is current opens the source
in another window instead of replacing it.")

(defvar texpresso-view--size nil
  "What was last asked of TeXpresso: (FILE WIDTH HEIGHT), in pixels.")

(defvar texpresso-view--source nil
  "The buffer whose file TeXpresso shows.")

(defvar texpresso-view--root nil
  "The file TeXpresso typesets: the source's own, or its `TeX-master'.")

(defvar texpresso-view--image nil
  "The image on display, to free it from the image cache when replaced.")

(defvar texpresso-view--png nil
  "The page on display in a graphical frame: (DATA WIDTH HEIGHT), its PNG.")

(defvar texpresso-view--page-source nil
  "Where the page on display starts in the source: (FILE LINE), or nil.")

(defvar texpresso-view--selected nil
  "The object selected on the page on display: its number, from 1, or nil.")

(defvar texpresso-view--outline nil
  "The outline drawn while an object is dragged: (X Y W H) in slide units.")

(defvar texpresso-view--anchor nil
  "Where on the slide the last click was, in slide units: (X . Y), or nil.
New objects go there.")

(defvar texpresso-view--waiting nil
  "When the last change of a drag went to TeXpresso, until its page comes.")

(defvar texpresso-view--thumbs-dir nil
  "The folder where TeXpresso writes the strip's pictures, page-N.png.")

(defvar texpresso-view--thumbs nil
  "The strip's pictures: ((FILE PAGE WIDTH HEIGHT SOURCE LINE) …).")

(defvar texpresso-view--thumbs-new nil
  "The pictures of the request under way, newest first.")

(defvar texpresso-view--thumbs-pending nil
  "When the pictures were last asked for, until TeXpresso has sent them.")

(defvar texpresso-view--thumbs-timer nil
  "The timer that asks TeXpresso for the strip's pictures again.")

(defvar texpresso-view--strip-timer nil
  "The timer that draws the strip again.")

(defvar texpresso-view--strip-frames nil
  "The frames the strip shows: ((BUFFER BEG END TITLE) …), BEG a marker.")

(defvar texpresso-view-cell-size nil
  "The size of a terminal's character cell, (WIDTH . HEIGHT) in pixels.
Nil asks the terminal; set it if the terminal does not answer.")

(defvar texpresso-view--sixel nil
  "The page as a Sixel picture: (DATA WIDTH HEIGHT).")

(defvar texpresso-view--sixel-drawn nil
  "Where the picture was last drawn: (FRAME COLUMN ROW WIDTH HEIGHT), or nil.")

(defvar texpresso-view--sixel-timer nil
  "The pending drawing of the picture.")

(defvar texpresso-view--sixel-again nil
  "Non-nil when the picture must be drawn even where it already is.")

(defvar texpresso-view--sixel-dirty nil
  "Non-nil when a command ran since the picture was drawn.")

(defvar texpresso-view--sixel-idle-timer nil
  "Draws the picture again once Emacs is idle after commands.")

(defvar texpresso-view--sixel-around nil
  "What the windows Emacs may scroll showed when the picture was drawn.")

(defvar texpresso-view--sixel-repair nil
  "Non-nil when the frame must be drawn again with the picture.")

(defvar texpresso-view--sixel-held nil
  "The terminal told to hold its screen until the picture is drawn, or nil.")

(defun texpresso-view--window ()
  "The window showing the page, if any."
  (get-buffer-window texpresso-view-buffer-name t))

(defun texpresso-view--tty-p (&optional win)
  "Non-nil if WIN, by default the page's window, is in a text terminal.
The page is then a Sixel picture drawn over the window."
  (let ((win (or win (texpresso-view--window))))
    (and win (not (display-images-p (window-frame win))))))

(defun texpresso-view--file ()
  "The file TeXpresso writes the page to: a PNG, or Sixel in a terminal."
  (expand-file-name (format "texpresso-view-%d.%s" (emacs-pid)
                            (if (texpresso-view--tty-p) "six" "png"))
                    temporary-file-directory))

(defun texpresso-view--delete-files ()
  "Delete the page's files: the PNG, the Sixel and their unfinished copies.
A view moved between a graphical and a terminal frame wrote both."
  (let ((base (expand-file-name (format "texpresso-view-%d" (emacs-pid))
                                temporary-file-directory)))
    (dolist (file (delete-dups
                   (delq nil (list (car texpresso-view--size)
                                   (concat base ".png") (concat base ".six")))))
      (dolist (f (list file (concat file ".tmp")))
        (when (file-exists-p f)
          (ignore-errors (delete-file f)))))))

(add-hook 'kill-emacs-hook #'texpresso-view--delete-files)

(defun texpresso-view--send-size (&rest _)
  "Ask TeXpresso for the page at the size of its window; stop when it has none.
In a terminal, the size is `texpresso-view--sixel-size'; while the
terminal is asked its cells again (after a zoom), nothing is sent: the
answer sends it."
  (when (process-live-p texpresso--process)
    (let* ((win (texpresso-view--window))
           (tty (and win (texpresso-view--tty-p win)))
           (size (cond (tty
                        (cons (texpresso-view--file) (texpresso-view--sixel-size win)))
                       (win
                        (list (texpresso-view--file)
                              (window-body-width win t) (window-body-height win t))))))
      (unless (or (and tty (texpresso-view--cell-check (window-frame win)))
                  (equal size texpresso-view--size))
        (setq texpresso-view--size size)
        (if size
            (apply #'texpresso--send 'render-to size)
          (texpresso--send 'render-to "" 0 0))))))

(defvar-local texpresso-view--page-text nil
  "The page's part of the mode line: \" PAGE/COUNT\".")

(defvar-local texpresso-view--errors-text nil
  "The errors' part of the mode line: \" · N errors\", or nil.")

(defun texpresso-view--show (file page count width height &optional source line)
  "Show the PNG FILE, page PAGE (from 0) of COUNT, WIDTH x HEIGHT pixels.
SOURCE and LINE: where the page starts in the source, if TeXpresso knows."
  (texpresso-view--page-shown page source line)
  (let ((buf (get-buffer texpresso-view-buffer-name)))
    (cond
     ((not (and buf (file-readable-p file))))
     ((string-suffix-p ".six" file)
      (setq texpresso-view--sixel
            (list (with-temp-buffer
                    (set-buffer-multibyte nil)
                    (insert-file-contents-literally file)
                    (buffer-string))
                  width height))
      (with-current-buffer buf
        (when (texpresso-view--window)
          (texpresso-view--sixel-rows (window-body-height (texpresso-view--window))))
        (setq texpresso-view--page-text (format " %d/%d" (1+ page) count))
        (texpresso-view--mode-line))
      (texpresso-view--sixel-schedule t))
     (t
      (setq texpresso-view--png
            (list (with-temp-buffer
                    (set-buffer-multibyte nil)
                    (insert-file-contents-literally file)
                    (buffer-string))
                  width height))
      (with-current-buffer buf
        (setq texpresso-view--page-text (format " %d/%d" (1+ page) count))
        (texpresso-view--mode-line))
      (texpresso-view--draw-page)))))

(defun texpresso-view--draw-page ()
  "Show the page on display in its window, the object selected outlined."
  (let ((buf (get-buffer texpresso-view-buffer-name)))
    (when (and buf texpresso-view--png)
      (pcase-let ((`(,data ,width ,height) texpresso-view--png))
        (with-current-buffer buf
          (let ((inhibit-read-only t))
            (when texpresso-view--image
              (image-flush texpresso-view--image))
            (setq texpresso-view--image (texpresso-view--page-image data width height))
            (erase-buffer)
            ;; Centre the page in its window: TeXpresso fits it to the window,
            ;; so one side is filled and the other has room to share out.
            (let* ((win (texpresso-view--window))
                   (left (if win (max 0 (/ (- (window-body-width win t) width) 2)) 0))
                   (top (if win (max 0 (/ (- (window-body-height win t) height) 2)) 0)))
              (when (> top (frame-char-height))
                (insert (propertize " " 'display `(space :width (1) :height (,top)))
                        "\n"))
              (when (> left 0)
                (insert (propertize " " 'display `(space :width (,left))))))
            (insert-image texpresso-view--image)
            (goto-char (point-min))))))))

(defun texpresso-view--mode-line ()
  "Show the page and the error count in the page window's mode line."
  (setq mode-line-process
        (delq nil (list texpresso-view--page-text texpresso-view--errors-text)))
  (force-mode-line-update))

;;; In a text terminal (foot, xterm, WezTerm…), TeXpresso writes the page as
;;; a Sixel picture, which is drawn over the page's window, left blank:
;;; Emacs writes to a terminal only the cells that change, so the picture
;;; stays until the window moves or the frame is drawn again, after which it
;;; is drawn again.

(defun texpresso-view--sixel-rows (rows)
  "Fill the page's buffer with ROWS lines, blank but each unlike the others.
Each is a space in a colour of its own, which does not show.  When the
source window scrolls, Emacs moves the terminal's lines that it finds
again a few rows away, whole, and the picture with them: lines that
differ are never found again."
  (unless (= (count-lines (point-min) (point-max)) rows)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (dotimes (i rows)
        (insert (propertize " " 'face (list :foreground (format "#%06x" (1+ i))))
                (if (< (1+ i) rows) "\n" "")))
      (goto-char (point-min)))))

(defvar xterm-query-timeout)
(declare-function xterm--query "term/xterm" (query handlers &optional no-async))
(declare-function xterm--read-string "term/xterm" (term1 &optional term2))

(defun texpresso-view--tty-query (query reply end &optional end2)
  "Send QUERY to the selected frame's terminal; the answer after REPLY, to END.
END2: the answer ends with END followed by END2.  Nil if the terminal does
not answer within half a second."
  (require 'term/xterm)
  (let ((xterm-query-timeout 0.5))
    (catch 'answer
      (xterm--query query
                    `((,reply . ,(lambda () (throw 'answer (xterm--read-string end end2)))))
                    t)
      nil)))

(defun texpresso-view--rgb (answer)
  "A terminal's colour ANSWER, \"rgb:RRRR/GGGG/BBBB\", as RGB; nil if not one."
  (when (and answer
             (string-match "\\`rgb:\\([0-9a-f]+\\)/\\([0-9a-f]+\\)/\\([0-9a-f]+\\)" answer))
    (mapcar (lambda (i)
              (let ((h (match-string i answer)))
                (/ (string-to-number h 16) (float (1- (expt 16 (length h)))))))
            '(1 2 3))))

(defun texpresso-view--tty-color (number)
  "The terminal's colour NUMBER (10 the text, 11 the background), as RGB."
  (texpresso-view--rgb (texpresso-view--tty-query (format "\e]%d;?\e\\" number)
                                                  (format "\e]%d;" number) ?\e ?\\)))

(defun texpresso-view--sixel-terminal-p ()
  "Non-nil if the selected frame's terminal draws Sixel pictures.
Its primary device attributes include 4; the answer is kept with the
terminal.  The size of a character cell and the colours are asked again
each time, kept with the terminal too: a zoom changes the cells (and
`texpresso-view--cell-check' asks again then)."
  (let ((term (frame-terminal)))
    (unless (terminal-parameter term 'texpresso-view-sixel)
      (let ((attributes (texpresso-view--tty-query "\e[c" "\e[?" ?c)))
        (set-terminal-parameter
         term 'texpresso-view-sixel
         (if (and attributes (member "4" (split-string attributes ";"))) 'yes 'no))))
    (when (eq (terminal-parameter term 'texpresso-view-sixel) 'yes)
      (let ((cell (texpresso-view--cell-parse
                   (texpresso-view--tty-query "\e[16t" "\e[6;" ?t))))
        (when cell
          (set-terminal-parameter term 'texpresso-view-cell-size cell))
        (set-terminal-parameter term 'texpresso-view-cell-for
                                (cons (frame-width) (frame-height)))
        (set-terminal-parameter term 'texpresso-view-cell-asked nil))
      (set-terminal-parameter term 'texpresso-view-colors
                              (list (texpresso-view--tty-color 11)
                                    (texpresso-view--tty-color 10)))
      t)))

(defun texpresso-view--cell-parse (answer)
  "A cell size ANSWER, \"HEIGHT;WIDTH\", as (WIDTH . HEIGHT); nil if not one."
  (when (and answer (string-match "\\`\\([0-9]+\\);\\([0-9]+\\)\\'" answer))
    (cons (string-to-number (match-string 2 answer))
          (string-to-number (match-string 1 answer)))))

(defun texpresso-view--color (attribute)
  "The default face's colour ATTRIBUTE (`:background', `:foreground'), as RGB.
As the theme names it, in whichever frame: texpresso.el reads it through
the selected frame, and a terminal's frame gives its nearest colour
instead (#fdf6e3 becomes white).  Nil when Emacs has none."
  (let* ((frame (window-frame (or (texpresso-view--window) (selected-window))))
         (name (face-attribute 'default attribute frame))
         (values (and (stringp name)
                      (or (tty-color-standard-values (downcase name))
                          (and (display-graphic-p frame) (color-values name frame))))))
    (and values (mapcar (lambda (v) (/ v 65535.0)) values))))

(defun texpresso-view--colors ()
  "The page's colours, (BACKGROUND FOREGROUND) as RGB, each nil if unknown.
The theme's, as `texpresso-view--color' reads them; where Emacs has none
\(a terminal with no theme), the page's terminal's, as last asked."
  (let ((tty (terminal-parameter
              (frame-terminal (window-frame (or (texpresso-view--window) (selected-window))))
              'texpresso-view-colors)))
    (list (or (texpresso-view--color :background) (car tty))
          (or (texpresso-view--color :foreground) (cadr tty)))))

(defvar texpresso-view--theme-sending nil
  "Non-nil while `texpresso-view--theme' sends the colours itself.")

(defun texpresso-view--send-theme ()
  "Send TeXpresso the page's colours, when both are known.
TeXpresso stops on a `theme' message without colours."
  (pcase-let ((`(,bg ,fg) (texpresso-view--colors)))
    (when (and bg fg)
      (let ((texpresso-view--theme-sending t))
        (texpresso--send 'theme bg fg)))))

(defun texpresso-view--theme (command &rest _args)
  "Give TeXpresso the colours of the theme, exact, in every frame: COMMAND.
texpresso.el sends `theme' when it starts TeXpresso and when a theme is
enabled; this sends `texpresso-view--colors' instead: the theme's own
colours, or, in a terminal whose frame has none (no theme), the
terminal's."
  (when (and (eq command 'theme) (not texpresso-view--theme-sending))
    (texpresso-view--send-theme)
    t))

(advice-add 'texpresso--send :before-until #'texpresso-view--theme)

;;; A terminal recoloured from outside Emacs tells it nothing: Omarchy, on a
;;; theme switch, recolours foot with OSC 10/11, and Emacs, showing the
;;; terminal's own colours where it has no theme, changes with it, but no
;;; theme is enabled.  So for a while after the page's terminal gets the
;;; focus back (the switch was made in a menu or another window, and the
;;; terminal is recoloured a moment later), its colours are asked again
;;; each half second, without waiting for the answer, and TeXpresso gets
;;; them when they changed.

(defconst texpresso-view-tty-watch 10
  "Seconds the terminal's colours are asked again after it gets the focus.")

(defvar texpresso-view--tty-watch-timer nil
  "Asks the page's terminal its colours each half second, for a while.")

(defvar texpresso-view--tty-watch-end 0
  "When `texpresso-view--tty-watch-timer' stops, as `float-time'.")

(defun texpresso-view--tty-own-colors-p (win)
  "Non-nil if WIN is in a text terminal and the page takes the terminal's colours.
That is, Emacs has none of its own in WIN's frame: no theme there."
  (and (texpresso-view--tty-p win)
       (not (and (texpresso-view--color :background)
                 (texpresso-view--color :foreground)))))

(defun texpresso-view--tty-focus ()
  "When the page's terminal gets the focus back, watch its colours a while."
  (let ((win (texpresso-view--window)))
    (when (and win (process-live-p texpresso--process)
               (eq (frame-focus-state (window-frame win)) t)
               (texpresso-view--tty-own-colors-p win))
      (setq texpresso-view--tty-watch-end (+ (float-time) texpresso-view-tty-watch))
      (unless (timerp texpresso-view--tty-watch-timer)
        (setq texpresso-view--tty-watch-timer
              (run-with-timer 0.2 0.5 #'texpresso-view--tty-watch))))))

(add-function :after after-focus-change-function #'texpresso-view--tty-focus)

(defun texpresso-view--tty-watch-stop ()
  "Stop asking the terminal its colours."
  (when (timerp texpresso-view--tty-watch-timer)
    (cancel-timer texpresso-view--tty-watch-timer))
  (setq texpresso-view--tty-watch-timer nil))

(defun texpresso-view--tty-watch ()
  "Ask the page's terminal its colours, until the watch ends.
Not while a command runs: a command reading characters itself
\(`read-char', `read-event') would get the answer as typed text."
  (let ((win (texpresso-view--window)))
    (cond
     ((or (> (float-time) texpresso-view--tty-watch-end)
          (not (and win (process-live-p texpresso--process)
                    (texpresso-view--tty-own-colors-p win))))
      (texpresso-view--tty-watch-stop))
     ((not (or this-command (input-pending-p)))
      (texpresso-view--tty-ask (window-frame win))))))

(declare-function xterm--query "term/xterm" (query handlers &optional no-async))

(defun texpresso-view--tty-ask (frame)
  "Ask FRAME's terminal its colours, without waiting for the answers.
They come back as input, which `xterm--query''s handlers take out: the
background, then the text colour.  When they differ from the terminal's
colours known, these are replaced and TeXpresso gets them."
  (require 'term/xterm)
  (let ((term (frame-terminal frame))
        (xterm-query-timeout nil))      ; nil: `xterm--query' does not wait
    (with-selected-frame frame
      (xterm--query "\e]11;?\e\\"
                    `(("\e]11;"
                       . ,(lambda ()
                            (set-terminal-parameter
                             term 'texpresso-view-asked
                             (texpresso-view--rgb (xterm--read-string ?\e ?\\)))))))
      (xterm--query "\e]10;?\e\\"
                    `(("\e]10;"
                       . ,(lambda ()
                            (texpresso-view--tty-answered
                             term (texpresso-view--rgb (xterm--read-string ?\e ?\\))))))))))

(defun texpresso-view--tty-answered (term fg)
  "TERM answered its colours: the background asked before, and FG.
TeXpresso gets them if they changed."
  (let ((colors (list (terminal-parameter term 'texpresso-view-asked) fg)))
    (set-terminal-parameter term 'texpresso-view-asked nil)
    (when (and (car colors) fg
               (not (equal colors (terminal-parameter term 'texpresso-view-colors))))
      (set-terminal-parameter term 'texpresso-view-colors colors)
      (when (process-live-p texpresso--process)
        (texpresso-view--send-theme)))))

(defun texpresso-view--cell-size (frame)
  "The size of a character cell of FRAME's terminal, (WIDTH . HEIGHT) in pixels."
  (or texpresso-view-cell-size
      (terminal-parameter (frame-terminal frame) 'texpresso-view-cell-size)
      '(10 . 20)))

(defun texpresso-view--sixel-size (win)
  "The picture's size for the window WIN, (WIDTH HEIGHT) in pixels.
WIN's cells times their size, the height cut to whole Sixel bands of 6
pixels.  TeXpresso draws the page centred on a picture of this size,
in the theme's background, so each picture covers the last one."
  (pcase-let ((`(,cw . ,ch) (texpresso-view--cell-size (window-frame win))))
    (list (* (window-body-width win) cw)
          (* 6 (/ (* (window-body-height win) ch) 6)))))

;;; A zoom in the terminal (foot's C-+) changes the size of its cells, and
;;; with it the frame's rows and columns, which is all Emacs sees.  So when
;;; the frame's size changes, the terminal is asked its cells again (CSI 16
;;; t), without waiting, as the colours are; until it answers, no size is
;;; sent and no picture drawn.

(defvar texpresso-view--cell-timer nil
  "Asks the page's terminal its cell size, once it may.")

(defun texpresso-view--cell-check (frame)
  "Non-nil while FRAME's terminal is asked its cell size again.
It is asked when FRAME's size in cells changed since it last was.  A
cell size set by hand (`texpresso-view-cell-size') is never asked, nor
that of a terminal that did not answer at first."
  (let ((term (frame-terminal frame))
        (text (cons (frame-width frame) (frame-height frame))))
    (when (and (not texpresso-view-cell-size)
               (terminal-parameter term 'texpresso-view-cell-size)
               (not (equal text (terminal-parameter term 'texpresso-view-cell-for))))
      (set-terminal-parameter term 'texpresso-view-cell-for text)
      (set-terminal-parameter term 'texpresso-view-cell-asked 'due)
      (unless (timerp texpresso-view--cell-timer)
        (setq texpresso-view--cell-timer
              (run-with-timer 0 0.1 #'texpresso-view--cell-ask))))
    (terminal-parameter term 'texpresso-view-cell-asked)))

(defun texpresso-view--cell-stop ()
  "Stop asking the terminal its cell size."
  (when (timerp texpresso-view--cell-timer)
    (cancel-timer texpresso-view--cell-timer))
  (setq texpresso-view--cell-timer nil))

(defun texpresso-view--cell-ask ()
  "Ask the page's terminal its cell size, if it is due.
Not while a command runs (a `read-char' would get the answer as typed
text).  When no answer has come a second later, the size known is kept."
  (let* ((win (texpresso-view--window))
         (term (and win (frame-terminal (window-frame win))))
         (asked (and term (terminal-parameter term 'texpresso-view-cell-asked))))
    (cond
     ((not asked)
      (texpresso-view--cell-stop))
     ((eq asked 'due)
      (unless (or this-command (input-pending-p))
        (set-terminal-parameter term 'texpresso-view-cell-asked (float-time))
        (texpresso-view--cell-query (window-frame win))))
     ((> (- (float-time) asked) 1)
      (texpresso-view--cell-answered term nil)))))

(defun texpresso-view--cell-query (frame)
  "Ask FRAME's terminal its cell size, without waiting for the answer.
It comes back as input, which `xterm--query''s handler takes out, to
`texpresso-view--cell-answered'."
  (require 'term/xterm)
  (let ((term (frame-terminal frame))
        (xterm-query-timeout nil))      ; nil: `xterm--query' does not wait
    (with-selected-frame frame
      (xterm--query "\e[16t"
                    `(("\e[6;"
                       . ,(lambda ()
                            (texpresso-view--cell-answered
                             term (xterm--read-string ?t)))))))))

(defun texpresso-view--cell-forget (term)
  "TERM is no longer asked its cell size: its answer's handler goes for good.
The handler's own removal (`xterm--query''s) leaves the answer's start
bound to nil in TERM's `input-decode-map', which hides the keys that
start the same way (C-PageDown's \"\\e[6;5~\" and the like) for the rest
of the session: the binding itself is removed."
  (texpresso-view--cell-stop)
  (when (terminal-live-p term)
    (set-terminal-parameter term 'texpresso-view-cell-asked nil)
    (let ((frame (seq-find (lambda (f) (eq (frame-terminal f) term)) (frame-list))))
      (when frame
        (with-selected-frame frame
          (define-key input-decode-map "\e[6;" nil t))))))

(defun texpresso-view--cell-answered (term answer)
  "TERM answered its cell size, ANSWER (\"HEIGHT;WIDTH\"), or nil if it did not.
The page is asked for at its window's size in the cells known now."
  (texpresso-view--cell-forget term)
  (let ((cell (texpresso-view--cell-parse answer)))
    (when cell
      (set-terminal-parameter term 'texpresso-view-cell-size cell)))
  (texpresso-view--send-size)
  (texpresso-view--sixel-schedule))

(defun texpresso-view--sixel-place ()
  "Where the picture goes: (FRAME COLUMN ROW WIDTH HEIGHT), or nil.
COLUMN and ROW, from 0, are the terminal cell of the window's top left
corner: the picture is the window's size (`texpresso-view--sixel-size').
One of another size, made for another window or before a zoom, waits for
the page at this size: smaller, it would leave the last one showing
around it; larger, it would cover other windows, and past the bottom of
the terminal scroll it.  So does any while the cells are asked again."
  (let ((win (texpresso-view--window)))
    (when (and win texpresso-view--sixel (texpresso-view--tty-p win)
               (not (terminal-parameter (frame-terminal (window-frame win))
                                        'texpresso-view-cell-asked)))
      (pcase-let ((`(,left ,top ,_ ,_) (window-body-edges win))
                  (`(,_ ,width ,height) texpresso-view--sixel))
        (when (equal (list width height) (texpresso-view--sixel-size win))
          (list (window-frame win) left top width height))))))

(defun texpresso-view--sixel-schedule (&optional again)
  "Draw the picture once Emacs has drawn the frame, if it is not in place.
AGAIN: draw it even if it is, as a new page or a cleared terminal needs."
  (when again
    (setq texpresso-view--sixel-again t))
  (unless (timerp texpresso-view--sixel-timer)
    (setq texpresso-view--sixel-timer
          (run-with-timer 0 nil #'texpresso-view--sixel-draw))))

(defun texpresso-view--sixel-draw ()
  "Draw the picture over the page's window, in its terminal.
When it moved or left, or the terminal may have moved it (see
`texpresso-view--sixel-watch'), the frame is drawn again first: that
clears the old picture, which Emacs does not know of.  The terminal
shows the frame drawn again and the picture at once (a synchronized
update, CSI ? 2026 h and l), not the frame blank in between."
  (setq texpresso-view--sixel-timer nil)
  (let ((place (texpresso-view--sixel-place))
        (drawn texpresso-view--sixel-drawn)
        (again texpresso-view--sixel-again)
        (repair texpresso-view--sixel-repair))
    (setq texpresso-view--sixel-again nil
          texpresso-view--sixel-repair nil)
    (unless (and (equal place drawn) (not again))
      (let* ((old (car drawn))
             (redraw (and drawn (frame-live-p old)
                          (or repair (not (equal place drawn)))))
             (sync (or texpresso-view--sixel-held
                       (and redraw (eq old (tty-top-frame (frame-terminal old)))
                            (frame-terminal old)))))
        (unless (or (not sync) texpresso-view--sixel-held)
          (send-string-to-terminal "\e[?2026h" sync))
        (setq texpresso-view--sixel-held nil)
        (when redraw
          (redraw-frame old))
        (setq texpresso-view--sixel-drawn nil)
        (when place
          (pcase-let ((`(,frame ,col ,row ,_ ,_) place))
            (when (eq frame (tty-top-frame (frame-terminal frame)))
              (redisplay)
              (send-string-to-terminal
               (concat "\e7" (format "\e[%d;%dH" (1+ row) (1+ col))
                       (car texpresso-view--sixel) "\e8")
               (frame-terminal frame))
              (setq texpresso-view--sixel-drawn place
                    texpresso-view--sixel-around (texpresso-view--neighbours)
                    texpresso-view--sixel-dirty nil))))
        (when (and sync (terminal-live-p sync))
          (unless texpresso-view--sixel-drawn
            (redisplay))
          (send-string-to-terminal "\e[?2026l" sync))))))

;;; A terminal can move the picture by itself.  Emacs moves a terminal's
;;; lines (a scroll region and lines deleted or inserted) when it finds them
;;; again a few rows away: never those of the page's window, which are blank
;;; and no two alike, but those of a window above or below it, such as
;;; *texpresso-out* when TeX's output scrolls it.  foot (1.28) then moves
;;; every Sixel picture by as many lines, those outside the scrolled lines
;;; too: the picture is drawn again in place, but what it covered outside
;;; its window stays, over cells Emacs thinks unchanged (the menu bar).  So
;;; when a window Emacs may scroll changed, the frame is drawn again with
;;; the picture.

(defun texpresso-view--neighbours ()
  "What the windows whose lines Emacs may move in the terminal show.
They are the windows of the page's frame not wholly beside the page's
window (the minibuffer when taller than a line): for each, the window,
its buffer, start, point, horizontal scroll, height and the buffer's
text's tick."
  (let* ((win (texpresso-view--window))
         (top (and win (window-top-line win)))
         (bottom (and win (+ top (window-total-height win)))))
    (when win
      (delq nil
            (mapcar
             (lambda (w)
               (let ((wtop (window-top-line w))
                     (height (window-total-height w)))
                 (unless (or (eq w win)
                             (and (<= top wtop) (<= (+ wtop height) bottom))
                             (and (window-minibuffer-p w) (= height 1)))
                   (list w (window-buffer w) (window-start w) (window-point w)
                         (window-hscroll w) height
                         (buffer-chars-modified-tick (window-buffer w))))))
             (window-list (window-frame win) t))))))

(defun texpresso-view--sixel-watch (&rest _)
  "Before a redisplay, have the frame drawn again after it, if needed.
That is, when a window whose lines Emacs may move changed since the
picture was drawn: see `texpresso-view--neighbours'.  The terminal is
told to hold its screen until then (CSI ? 2026 h), so the picture it
moved never shows, but only when no input is pending: the drawing, on a
timer, waits until Emacs waits for input, and a terminal held longer
than a second lets go by itself."
  (when (and texpresso-view--sixel-drawn (not texpresso-view--sixel-repair))
    (let ((around (texpresso-view--neighbours)))
      (unless (equal around texpresso-view--sixel-around)
        (setq texpresso-view--sixel-around around
              texpresso-view--sixel-repair t)
        (let* ((frame (car texpresso-view--sixel-drawn))
               (term (and (frame-live-p frame) (frame-terminal frame))))
          (when (and term (not texpresso-view--sixel-held)
                     (eq frame (tty-top-frame term))
                     (not (input-pending-p)))
            (send-string-to-terminal "\e[?2026h" term)
            (setq texpresso-view--sixel-held term)))
        (texpresso-view--sixel-schedule t)))))

(defun texpresso-view--sixel-after-command ()
  "After a command, have the picture drawn again if the frame may have been.
\\[recenter-top-bottom] and \\[redraw-display] clear the terminal at once;
a menu or a pop-up drawn over the window shows when Emacs is idle."
  (when texpresso-view--sixel-drawn
    (if (memq this-command '(recenter-top-bottom recenter redraw-display))
        (texpresso-view--sixel-schedule t)
      (setq texpresso-view--sixel-dirty t))))

(defun texpresso-view--sixel-idle ()
  "Draw the picture again after commands, once Emacs is idle."
  (when texpresso-view--sixel-dirty
    (setq texpresso-view--sixel-dirty nil)
    (texpresso-view--sixel-schedule t)))

(defun texpresso-view--sixel-moved (&rest _)
  "Draw the picture where the page's window now is, if it moved."
  (when (or texpresso-view--sixel-drawn texpresso-view--sixel)
    (texpresso-view--sixel-schedule)))

(defun texpresso-view--sixel-resumed (&rest _)
  "Draw the picture again: the terminal came back cleared."
  (when texpresso-view--sixel
    (texpresso-view--sixel-schedule t)))

(add-hook 'post-command-hook #'texpresso-view--sixel-after-command)
(add-hook 'window-configuration-change-hook #'texpresso-view--sixel-moved)
(add-hook 'resume-tty-functions #'texpresso-view--sixel-resumed)
(add-hook 'pre-redisplay-functions #'texpresso-view--sixel-watch)

;;; TeX's errors.  TeXpresso streams TeX's log to Emacs, appending to it and
;;; truncating it as it typesets and goes back, so the log on hand is that of
;;; the text as it stands: its "! " lines are the text's errors.  When the
;;; text stops TeX (an argument open to the end of the file, a missing
;;; \end{document}, TeX's capacity exceeded), a red line over the page says
;;; so; the other errors are counted in the page window's mode line.  Where
;;; an error is comes from TeXpresso's stderr, where TeX's engine prints
;;; "Error: FILE:LINE: MESSAGE".

(defvar texpresso-view--log nil
  "A copy of TeX's log as TeXpresso streams it: a unibyte buffer.")

(defvar texpresso-view--log-known nil
  "Non-nil while `texpresso-view--log' holds the log from its start.
A TeXpresso that was running before the view opened streams past the
copy's end; the copy is known again once the log is cut back within it.")

(defvar texpresso-view--locations nil
  "Where TeX's latest errors are, newest first: a list of (MESSAGE LINE FILE).")

(defvar texpresso-view--stderr-rest ""
  "The start of a line of TeXpresso's stderr not yet ended.")

(defvar texpresso-view--errors-timer nil
  "The pending look at the copy of TeX's log.")

(defvar texpresso-view--stop-since nil
  "When the copy of TeX's log first said that TeX stopped, or nil.")

(defconst texpresso-view-stop-delay 1.0
  "Seconds a stop of TeX lasts before the view says so.
An argument whose closing brace is not typed yet stops TeX: the red line
waits for a pause.")

(defconst texpresso-view--stop-regexp
  (concat "^\\(?:! \\(?:Emergency stop\\|TeX capacity exceeded\\|This can't happen"
          "\\|I can't go on meeting you like this\\)\\|(That makes 100 errors\\)")
  "A line of TeX's log saying that TeX stopped.")

(defun texpresso-view--log-reset ()
  "Start an empty copy of TeX's log, with no errors known."
  (unless (buffer-live-p texpresso-view--log)
    (setq texpresso-view--log (generate-new-buffer " *texpresso-view-log*"))
    (with-current-buffer texpresso-view--log
      (set-buffer-multibyte nil)
      (setq buffer-undo-list t)))
  (with-current-buffer texpresso-view--log
    (erase-buffer))
  (when (timerp texpresso-view--errors-timer)
    (cancel-timer texpresso-view--errors-timer))
  (setq texpresso-view--log-known nil
        texpresso-view--locations nil
        texpresso-view--stderr-rest ""
        texpresso-view--errors-timer nil
        texpresso-view--stop-since nil))

(defun texpresso-view--log-update (offset &optional text)
  "Cut the copy of TeX's log at byte OFFSET, then add TEXT, if any."
  (when (buffer-live-p texpresso-view--log)
    (with-current-buffer texpresso-view--log
      (if (> offset (buffer-size))
          (setq texpresso-view--log-known nil)
        (delete-region (1+ offset) (point-max))
        (when text
          (goto-char (point-max))
          (insert (encode-coding-string text 'utf-8)))
        (setq texpresso-view--log-known t)))
    (texpresso-view--errors-schedule 0.3)
    ;; TeX typesets again: the strip's pictures follow once it pauses
    (texpresso-view--thumbs-schedule)))

(defun texpresso-view--stderr (_process text)
  "Note where TeX's errors are, from the lines of TeXpresso's stderr in TEXT."
  (let ((lines (split-string (concat texpresso-view--stderr-rest text) "\n")))
    (setq texpresso-view--stderr-rest (car (last lines)))
    (dolist (line (butlast lines))
      ;; "Error: !Emergency stop" and the like say no place
      (when (string-match "\\`Error: \\([^!:\n][^:\n]*\\):\\([0-9]+\\): \\(.*\\)" line)
        (push (list (match-string 3 line) (string-to-number (match-string 2 line))
                    (match-string 1 line))
              texpresso-view--locations)))
    (when (nthcdr 50 texpresso-view--locations)
      (setcdr (nthcdr 49 texpresso-view--locations) nil))))

(advice-add 'texpresso--stderr-filter :before #'texpresso-view--stderr)

(defun texpresso-view--log-line ()
  "The line of the copy of TeX's log at point, as text."
  (decode-coding-string
   (buffer-substring-no-properties (line-beginning-position) (line-end-position))
   'utf-8))

(defun texpresso-view--log-error ()
  "The error whose \"! \" line is at point: (MESSAGE LINE CONTEXT).
LINE is the source line TeX gives (\"l.14\"), CONTEXT the text of a runaway
argument; either may be nil."
  (let ((message (substring (texpresso-view--log-line) 2))
        line context)
    (save-excursion
      (when (and (zerop (forward-line -2))
                 (equal (texpresso-view--log-line) "Runaway argument?")
                 (zerop (forward-line 1)))
        (setq context (texpresso-view--log-line))))
    (save-excursion
      (let ((limit (save-excursion (forward-line 15) (point))))
        (forward-line 1)
        (when (and (re-search-forward "^\\(?:! \\|l\\.\\([0-9]+\\) \\)" limit t)
                   (match-beginning 1))
          (setq line (string-to-number (match-string 1))))))
    (list message line context)))

(defun texpresso-view--log-errors ()
  "What the copy of TeX's log says: (STOP CAUSE PAGES ERRORS).
ERRORS lists the errors (MESSAGE LINE CONTEXT) before any stop, in order.
STOP is what TeX said when it stopped, or nil; CAUSE the error that made it
stop, when TeX stopped right after one (a runaway argument); PAGES how many
pages TeX wrote, when it said."
  (with-current-buffer texpresso-view--log
    (save-excursion
      (goto-char (point-min))
      (let (errors last stop cause pages)
        (while (and (not stop)
                    (re-search-forward "^\\(?:! \\|(That makes 100 errors\\)" nil t))
          (goto-char (match-beginning 0))
          (if (not (looking-at texpresso-view--stop-regexp))
              (progn (push (texpresso-view--log-error) errors)
                     (setq last (point)))
            (setq stop (string-remove-prefix "! " (texpresso-view--log-line)))
            (when (looking-at "! TeX capacity exceeded")
              ;; an error of its own, with its line
              (setq cause (texpresso-view--log-error)))
            (when (equal stop "Emergency stop")
              ;; an error just before the emergency stop is its cause
              (when (and last (< (count-lines last (point)) 12))
                (setq cause (car errors)))
              ;; and the line "*** (…)" after it says why TeX gave up
              (save-excursion
                (forward-line 1)
                (when (looking-at "\\(?:[< ].*\n\\|\n\\)*\\*\\*\\* (\\(.*\\))")
                  (setq stop (decode-coding-string (match-string 1) 'utf-8))))))
          (forward-line 1))
        (when (re-search-forward "^Output written on [^ ]+ (\\([0-9]+\\) page" nil t)
          (setq pages (string-to-number (match-string 1))))
        (list stop cause pages (nreverse errors))))))

(defun texpresso-view--error-place (error)
  "Where ERROR, (MESSAGE LINE CONTEXT), is: \"FILE:LINE\", \"line LINE\", or nil."
  (pcase-let ((`(,message ,line ,_) error))
    (let ((found (seq-find (lambda (l)
                             (and (equal (nth 1 l) line)
                                  (equal (car l) (string-remove-suffix "." message))))
                           texpresso-view--locations)))
      (cond (found (format "%s:%d" (nth 2 found) line))
            (line (format "line %d" line))))))

(defun texpresso-view--error-text (error)
  "ERROR, (MESSAGE LINE CONTEXT), in a few words."
  (pcase-let ((`(,message ,_ ,context) error))
    (let ((place (texpresso-view--error-place error)))
      (concat (string-remove-suffix "." (string-remove-prefix "! " message))
              (and place (concat " (" place ")"))
              (and context (concat ", near "
                                   (truncate-string-to-width (string-trim context)
                                                             40 nil nil "…")))))))

(defun texpresso-view--errors-schedule (delay)
  "Look at the copy of TeX's log in DELAY seconds, unless a look is pending."
  (unless (timerp texpresso-view--errors-timer)
    (setq texpresso-view--errors-timer
          (run-with-timer delay nil #'texpresso-view--errors-show))))

(defun texpresso-view--errors-show ()
  "Say in the page window what the copy of TeX's log says about errors."
  (setq texpresso-view--errors-timer nil)
  (let ((buf (get-buffer texpresso-view-buffer-name)))
    (when (and buf texpresso-view--log-known (buffer-live-p texpresso-view--log))
      (pcase-let ((`(,stop ,cause ,pages ,errors) (texpresso-view--log-errors)))
        (with-current-buffer buf
          (setq texpresso-view--errors-text
                (and errors
                     (propertize (format " · %d error%s" (length errors)
                                         (if (cdr errors) "s" ""))
                                 'face 'warning
                                 'help-echo (texpresso-view--error-text (car errors)))))
          (texpresso-view--mode-line)
          (cond
           ((not stop)
            (setq texpresso-view--stop-since nil)
            (when header-line-format
              (setq header-line-format nil)))
           ((not texpresso-view--stop-since)
            (setq texpresso-view--stop-since (float-time))
            (texpresso-view--errors-schedule texpresso-view-stop-delay))
           ((< (- (float-time) texpresso-view--stop-since) texpresso-view-stop-delay)
            (texpresso-view--errors-schedule
             (- texpresso-view-stop-delay (- (float-time) texpresso-view--stop-since))))
           (t
            (let ((text (concat "TeX stopped"
                                (and pages (format " after page %d" pages))
                                ": "
                                (if cause (texpresso-view--error-text cause)
                                  (string-remove-suffix "." stop)))))
              (setq header-line-format
                    (propertize (replace-regexp-in-string "%" "%%" text t t)
                                'face 'error 'help-echo text))))))))))

(defvar texpresso-view--click-pending nil
  "Non-nil from a click in the page until TeXpresso answers with its source.")

(defun texpresso-view--dispatch (_process expr)
  "Take TeXpresso's message EXPR if it is a `page-image' or `selected-text'.
Let texpresso.el have the others."
  (pcase (car-safe expr)
    ('page-image
     (apply #'texpresso-view--show (cdr expr))
     t)
    ('thumbnail
     (push (cdr expr) texpresso-view--thumbs-new)
     t)
    ('thumbnails-done
     (texpresso-view--thumbs-done (nth 1 expr) (nth 2 expr))
     t)
    ('selected-text
     (let ((text (string-trim (nth 1 expr))))
       (if (string-empty-p text)
           (message "TeXpresso: no text there")
         (kill-new text)
         (message "Copied: %s" (truncate-string-to-width
                                (replace-regexp-in-string "\n" " " text) 70 nil nil "…"))))
     t)
    ('synctex
     (setq texpresso-view--click-pending nil)
     (texpresso-view--synctex (nth 1 expr) (nth 2 expr)))
    ((or 'append 'truncate)
     ;; texpresso.el keeps its *texpresso-log* too: the message goes on
     (when (eq (nth 1 expr) 'log)
       (texpresso-view--log-update (nth 2 expr) (nth 3 expr)))
     nil)))

(advice-add 'texpresso--stdout-dispatch :before-until #'texpresso-view--dispatch)

(defun texpresso-view--synctex (file line)
  "Show LINE of FILE in the source window, the page's window staying selected.
Nil when the page's window is not selected: texpresso.el then opens the
file itself, selecting it."
  (let ((page (texpresso-view--window))
        (win (texpresso-view--source-window)))
    (when (and page win (eq (selected-window) page) (file-exists-p file))
      (with-selected-window win
        (find-file file)
        (goto-char (point-min))
        (forward-line (1- line)))
      t)))

(defun texpresso-view--sixel-xy (posn)
  "The point of the Sixel picture at POSN, the middle of its cell, in pixels."
  (pcase-let* ((place texpresso-view--sixel-drawn)
               (win (posn-window posn))
               (`(,col . ,row) (posn-col-row posn))
               (`(,left ,top ,_ ,_) (window-body-edges win))
               (`(,cw . ,ch) (texpresso-view--cell-size (window-frame win))))
    (when (and place (eq (window-frame win) (car place)))
      (cons (+ (* (- (+ left col) (nth 1 place)) cw) (/ cw 2))
            (+ (* (- (+ top row) (nth 2 place)) ch) (/ ch 2))))))

(defun texpresso-view--object-xy (event)
  "The points where EVENT starts and ends, in pixels of the page image.
The end is measured from the start, so a drag that leaves the image still
counts."
  (let* ((start (event-start event))
         (end (event-end event))
         (a (posn-object-x-y start))
         (sx (posn-x-y start))
         (ex (posn-x-y end)))
    (cond
     ((texpresso-view--tty-p (posn-window start))
      (let ((a (texpresso-view--sixel-xy start))
            (b (texpresso-view--sixel-xy end)))
        (and a b (list (car a) (cdr a) (car b) (cdr b)))))
     (a
      (list (car a) (cdr a)
            (+ (car a) (- (car ex) (car sx)))
            (+ (cdr a) (- (cdr ex) (cdr sx))))))))

(defun texpresso-view-click (event)
  "Jump to the source of the point of the page clicked in EVENT.
The page's window is selected, so its keys work at once; the source
window shows the line (`texpresso-view--synctex')."
  (interactive "e")
  (select-window (posn-window (event-start event)))
  (let ((pts (texpresso-view--object-xy event)))
    (when (and pts (process-live-p texpresso--process))
      (setq texpresso-view--click-pending t)
      (texpresso--send 'click-at (nth 0 pts) (nth 1 pts))
      (run-with-timer
       0.6 nil
       (lambda ()
         (when texpresso-view--click-pending
           (setq texpresso-view--click-pending nil)
           (message "TeXpresso: no source line there")))))))

(defun texpresso-view-select (event)
  "Copy the text of the page from where the drag EVENT starts to where it ends.
TeXpresso highlights it in the page.  The page's window is selected."
  (interactive "e")
  (select-window (posn-window (event-start event)))
  (let ((pts (texpresso-view--object-xy event)))
    (when (and pts (process-live-p texpresso--process))
      (apply #'texpresso--send 'select pts))))

(defun texpresso-view-next ()
  "Next page; the source shows where it starts."
  (interactive)
  (texpresso-view--turn 1))

(defun texpresso-view-previous ()
  "Previous page; the source shows where it starts."
  (interactive)
  (texpresso-view--turn -1))

(defvar texpresso-view--wheel-time 0
  "When the mouse wheel last turned a page.")

(defun texpresso-view-wheel (event)
  "Turn the page with the mouse wheel EVENT, one page every 0.3 s at most.
A touchpad sends many wheel events for one stroke."
  (interactive "e")
  (when (> (- (float-time) texpresso-view--wheel-time) 0.3)
    (setq texpresso-view--wheel-time (float-time))
    (texpresso-view--turn
     (if (memq (event-basic-type event) '(wheel-down mouse-5)) 1 -1))))

;;; Scroll sync: the source follows the pages turned, the page the source
;;; scrolled.  TeXpresso's own `texpresso-follow-cursor' moves the page to
;;; the cursor's line after every other command.

(defvar texpresso-view--source-window nil
  "The window the source was in when the view opened.")

(defvar texpresso-view--page nil
  "The page on display, from 0.")

(defvar texpresso-view--turn nil
  "A page turned from the view and not yet shown: (PAGE . TIME asked).")

(defvar texpresso-view--scroll-timer nil
  "The pending move of the page to a scrolled source.")

(defconst texpresso-view--page-commands
  '(texpresso-view-click texpresso-view-select texpresso-view-next
    texpresso-view-previous texpresso-view-wheel ignore
    texpresso-view-mouse-down texpresso-view-down texpresso-view-right
    texpresso-view-up texpresso-view-left texpresso-view-backspace)
  "Commands of the page's window: after them the page does not follow the cursor.
The wheel on the page leaves the source window selected; a click selects
the page's window.")

(defun texpresso-view--source-window ()
  "The window of the source, if any."
  (cond ((window-live-p texpresso-view--source-window)
         texpresso-view--source-window)
        ((buffer-live-p texpresso-view--source)
         (get-buffer-window texpresso-view--source))))

(defun texpresso-view--turn (step)
  "Turn STEP pages, and have the source follow once the page is shown."
  (when (process-live-p texpresso--process)
    (let* ((turn texpresso-view--turn)
           (from (if (and turn (< (- (float-time) (cdr turn)) 2))
                     (car turn)
                   texpresso-view--page)))
      (when from
        (setq texpresso-view--turn (cons (+ from step) (float-time)))))
    (texpresso--send (if (> step 0) 'next-page 'previous-page))))

(defun texpresso-view--page-shown (page source line)
  "PAGE is on display, starting at LINE of SOURCE: follow it if it was turned."
  (unless (eql page texpresso-view--page)
    (setq texpresso-view--selected nil
          texpresso-view--page-source nil)
    (texpresso-view--strip-schedule))
  ;; the same page sent while SyncTeX has no line for it yet keeps the one known
  (when source
    (setq texpresso-view--page-source (list source line)))
  (setq texpresso-view--page page
        texpresso-view--waiting nil)
  (let ((turn texpresso-view--turn))
    (when (and turn (= page (car turn)))
      (setq texpresso-view--turn nil)
      (when (and source (< (- (float-time) (cdr turn)) 2))
        (texpresso-view--show-source source line)))))

(defun texpresso-view--page-start (pos)
  "Where the page whose source starts at POS begins: a frame's \\begin{frame}.
Beamer typesets a frame when it reads its \\end{frame}, which SyncTeX
gives as the frame's source."
  (save-excursion
    (goto-char pos)
    (or (and (looking-at "[ \t]*\\\\end{frame}")
             (re-search-backward "^[ \t]*\\\\begin{frame}" nil t)
             (line-beginning-position))
        pos)))

(defun texpresso-view--show-source (file line)
  "Show LINE of FILE at the top of the source window, the cursor on it."
  (let* ((file (expand-file-name file))
         (win (texpresso-view--source-window))
         (buf (and win (or (find-buffer-visiting file)
                           (and (file-exists-p file) (find-file-noselect file))))))
    (when buf
      (unless (eq (window-buffer win) buf)
        (set-window-buffer win buf))
      (let ((pos (with-current-buffer buf
                   (save-restriction
                     (widen)
                     (goto-char (point-min))
                     (forward-line (1- line))
                     (texpresso-view--page-start (point))))))
        (set-window-point win pos)
        (set-window-start win pos)))))

(defun texpresso-view--scroll-command-p (command)
  "Non-nil if COMMAND scrolls (the mouse wheel, \\[scroll-up-command] …)."
  (and command (symbolp command)
       (string-match-p "scroll" (symbol-name command))))

(defun texpresso-view--source-scrolled (win _start)
  "After a scroll command moved WIN, the source window, show its top line's page.
Waits for the scrolling to pause."
  (when (and (eq win (texpresso-view--source-window))
             (texpresso-view--scroll-command-p last-command)
             (process-live-p texpresso--process)
             (texpresso-view--window))
    (when (timerp texpresso-view--scroll-timer)
      (cancel-timer texpresso-view--scroll-timer))
    (setq texpresso-view--scroll-timer
          (run-with-timer 0.15 nil #'texpresso-view--follow-scroll win))))

(defun texpresso-view--input-file (pos)
  "The file that the \\input or \\include on the line at POS reads, if any."
  (save-excursion
    (goto-char pos)
    (when (looking-at "[ \t]*\\\\\\(?:input\\|include\\){\\([^}]+\\)}")
      (let ((file (expand-file-name (match-string 1))))
        (seq-find #'file-exists-p (list file (concat file ".tex")))))))

(defun texpresso-view--follow-scroll (win)
  "Show the page of the line at the top of WIN.
An \\input line stands for the start of the file it reads: SyncTeX knows
the pages typeset from it by that file's lines."
  (setq texpresso-view--scroll-timer nil)
  (when (and (window-live-p win) (process-live-p texpresso--process))
    (with-current-buffer (window-buffer win)
      (when (buffer-file-name)
        (let* ((start (save-excursion
                        ;; blank lines and comments have no page: the
                        ;; first line with text below stands for them
                        (goto-char (window-start win))
                        (while (and (looking-at "[ \t]*\\(?:%.*\\)?$")
                                    (zerop (forward-line 1))
                                    (not (eobp))))
                        (point)))
               (input (texpresso-view--input-file start)))
          (if input
              (texpresso--send 'synctex-forward input 1)
            (texpresso--send 'synctex-forward (buffer-file-name)
                             (line-number-at-pos start t))))))))

(defun texpresso-view--follow-cursor-p ()
  "Nil while the view is open, after a scroll or a command of the page's window.
The page then follows the scroll or the page turned, not the cursor."
  (not (and (buffer-live-p texpresso-view--source)
            (or (memq this-command texpresso-view--page-commands)
                (texpresso-view--scroll-command-p this-command)))))

(advice-add 'texpresso--post-command :before-while #'texpresso-view--follow-cursor-p)
(add-hook 'window-scroll-functions #'texpresso-view--source-scrolled)

;;; Slides edited with the mouse, as in Google Slides.  What is placed on a
;;; slide (a picture, a text box) is a TikZ node in the frame's tvlayer:
;;;
;;;   \begin{tvlayer}
;;;     \node[tv] at (10,20) {\includegraphics[width=30\tvu]{figures/a.png}};
;;;   \end{tvlayer}
;;;
;;; drawn over the slide when it is shipped out, at (x,y) from its top left
;;; corner in hundredths of the slide's width (\tvu), whatever its aspect
;;; ratio.  The definitions go once before \begin{document}
;;; (`texpresso-view-slides-preamble'), plain LaTeX and TikZ, so the deck
;;; builds with any engine.  TeX writes each object's place and size to its
;;; log, "texpresso-view: PAGE K X Y W H": the view reads them to know what
;;; is under the mouse; a drag rewrites the node's numbers in the source,
;;; and TeXpresso shows them at once.

(defconst texpresso-view-slides-preamble
  "% texpresso-view slides: begin
% What texpresso-view places on a slide with the mouse: in a frame's tvlayer,
% TikZ nodes drawn over the slide, at (x,y) from its top left corner, in
% hundredths of its width (\\tvu).  TeX writes each one's place and size to
% the log, which is how texpresso-view finds them on the page.
\\usepackage{tikz}
\\makeatletter
\\newlength\\tvu
\\AtBeginDocument{\\setlength\\tvu{0.01\\paperwidth}}
\\newcount\\tv@n
\\tikzset{tv/.code={\\global\\advance\\tv@n by 1
  \\tikzset{anchor=north west,inner sep=0pt,outer sep=0pt,name=tv@\\the\\tv@n}}}
\\NewDocumentEnvironment{tvlayer}{+b}
  {\\AddToHookNext{shipout/foreground}{\\tv@layer{#1}}}{}
\\newcommand\\tv@layer[1]{\\global\\tv@n=0
  \\put(0,0){\\begin{tikzpicture}[x=\\tvu,y=-\\tvu,baseline=0pt]
    \\useasboundingbox (0,0) rectangle (1,1);
    #1
    \\tv@report
  \\end{tikzpicture}}}
\\newcommand\\tv@report{\\ifnum\\tv@n>0
  \\foreach\\tv@k in {1,...,\\the\\tv@n}{%
    \\pgfpointanchor{tv@\\tv@k}{north west}%
    \\pgfmathsetmacro\\tv@x{\\pgf@x/\\tvu}\\pgfmathsetmacro\\tv@y{-\\pgf@y/\\tvu}%
    \\pgfpointdiff{\\pgfpointanchor{tv@\\tv@k}{north west}}%
      {\\pgfpointanchor{tv@\\tv@k}{south east}}%
    \\pgfmathsetmacro\\tv@w{\\pgf@x/\\tvu}\\pgfmathsetmacro\\tv@h{-\\pgf@y/\\tvu}%
    \\typeout{texpresso-view: \\the\\ReadonlyShipoutCounter\\space\\tv@k\\space
      \\tv@x\\space\\tv@y\\space\\tv@w\\space\\tv@h}}\\fi}
\\makeatother
% texpresso-view slides: end
"
  "What a deck needs for objects placed with the mouse.
It goes before \\begin{document}.")

(defconst texpresso-view--outline-color "#1a73e8"
  "The colour of the outline and handles of the object selected.")

(defun texpresso-view--units-per-pixel ()
  "Slide units in a pixel of the page on display: 100 to the slide's width."
  (/ 100.0 (nth 1 texpresso-view--png)))

(defun texpresso-view--objects ()
  "The objects on the page on display, as TeX placed them: ((K X Y W H) …).
K is the object's number in its frame's tvlayer, from 1."
  (when (and texpresso-view--page (buffer-live-p texpresso-view--log))
    (with-current-buffer texpresso-view--log
      (save-excursion
        (goto-char (point-min))
        (let ((re (concat (format "^texpresso-view: %d \\([0-9]+\\)" (1+ texpresso-view--page))
                          (apply #'concat (make-list 4 " \\(-?[0-9.]+\\)"))
                          "$"))
              objects)
          (while (re-search-forward re nil t)
            (let ((k (string-to-number (match-string 1))))
              (setq objects (cons (cons k (mapcar (lambda (i) (string-to-number (match-string i)))
                                                  '(2 3 4 5)))
                                  (assq-delete-all k objects)))))
          (sort objects (lambda (a b) (< (car a) (car b)))))))))

(defun texpresso-view--box ()
  "The outline to draw: the one dragged, or the object selected's, or nil."
  (or texpresso-view--outline
      (and texpresso-view--selected
           (cdr (assq texpresso-view--selected (texpresso-view--objects))))))

(defun texpresso-view--page-image (data width height)
  "The page's image from its PNG DATA, WIDTH x HEIGHT, the selection outlined.
With an outline, an SVG that holds the PNG and draws the outline and its
four handles over it."
  (let ((box (texpresso-view--box)))
    (if (not (and box (image-type-available-p 'svg)))
        (create-image data 'png t :scale 1.0 :width width :height height)
      (let ((svg (svg-create width height))
            (u (/ width 100.0))
            (color texpresso-view--outline-color))
        (svg-embed svg data "image/png" t :x 0 :y 0 :width width :height height)
        (pcase-let ((`(,x ,y ,w ,h) box))
          (svg-rectangle svg (* x u) (* y u) (* w u) (* h u)
                         :fill "none" :stroke color :stroke-width 2)
          (dolist (corner (list (cons x y) (cons (+ x w) y)
                                (cons x (+ y h)) (cons (+ x w) (+ y h))))
            (svg-rectangle svg (- (* (car corner) u) 4) (- (* (cdr corner) u) 4) 8 8
                           :fill "white" :stroke color :stroke-width 1.5)))
        (svg-image svg :scale 1.0)))))

(defun texpresso-view--hit (x y)
  "The object at X Y on the slide, the topmost: (K CORNER), or nil.
CORNER is one of `nw', `ne', `sw', `se' for a handle of the object
selected, nil inside an object."
  (let ((r (min 2.0 (max 0.8 (* 6 (texpresso-view--units-per-pixel)))))
        hit)
    (dolist (object (texpresso-view--objects))
      (pcase-let ((`(,k ,ox ,oy ,w ,h) object))
        (let ((corner (and (eql k texpresso-view--selected)
                           (seq-find (lambda (c) (and (<= (abs (- x (nth 1 c))) r)
                                                      (<= (abs (- y (nth 2 c))) r)))
                                     (list (list 'nw ox oy) (list 'ne (+ ox w) oy)
                                           (list 'sw ox (+ oy h)) (list 'se (+ ox w) (+ oy h)))))))
          (when (or corner (and (<= ox x (+ ox w)) (<= oy y (+ oy h))))
            (setq hit (list k (car corner)))))))
    hit))

(defvar texpresso-view--frame-start nil
  "The \\begin{frame} of the page on display: (SOURCE . MARKER).
SOURCE is the `texpresso-view--page-source' it was found from: the
marker follows the edits made until the next page comes.")

(defun texpresso-view--frame-marker ()
  "A marker at the \\begin{frame} of the page on display, or nil."
  (let ((cached texpresso-view--frame-start))
    (if (and cached (eq (car cached) texpresso-view--page-source)
             (marker-buffer (cdr cached)))
        (cdr cached)
      (pcase-let ((`(,file ,line) texpresso-view--page-source))
        (when (and file texpresso-view--root)
          (let* ((file (expand-file-name file (file-name-directory texpresso-view--root)))
                 (buf (or (find-buffer-visiting file)
                          (and (file-exists-p file) (find-file-noselect file)))))
            (when buf
              (with-current-buffer buf
                (save-restriction
                  (widen)
                  (save-excursion
                    (goto-char (point-min))
                    (forward-line (1- line))
                    (let ((here (point)))
                      (end-of-line)
                      ;; the page's line is in its frame: beamer gives its \end{frame};
                      ;; a frame that ends before it is another's, the page a macro's
                      (when (and (re-search-backward "^[ \t]*\\\\begin{frame}" nil t)
                                 (save-excursion
                                   (and (re-search-forward "\\\\end{frame}" nil t)
                                        (>= (point) here))))
                        (let ((marker (point-marker)))
                          (setq texpresso-view--frame-start
                                (cons texpresso-view--page-source marker))
                          marker)))))))))))))

(defun texpresso-view--frame ()
  "The frame of the page on display: (BUFFER BEG END), or nil.
BEG is at its \\begin{frame}, END after its \\end{frame}."
  (let ((start (texpresso-view--frame-marker)))
    (when start
      (with-current-buffer (marker-buffer start)
        (save-restriction
          (widen)
          (save-excursion
            (goto-char start)
            (when (re-search-forward "\\\\end{frame}" nil t)
              (list (current-buffer) (marker-position start) (point)))))))))

(defun texpresso-view--layer (beg end)
  "The tvlayer between BEG and END of this buffer: (FROM . TO), or nil.
FROM is after its \\begin{tvlayer}, TO at its \\end{tvlayer}."
  (save-excursion
    (goto-char beg)
    (when (re-search-forward "\\\\begin{tvlayer}" end t)
      (let ((from (point)))
        (when (re-search-forward "\\\\end{tvlayer}" end t)
          (cons from (match-beginning 0)))))))

(defun texpresso-view--statement-end (pos limit)
  "After the semicolon that ends the TikZ statement at POS, before LIMIT."
  (save-excursion
    (goto-char pos)
    (let ((depth 0) end)
      (while (and (not end) (< (point) limit))
        (let ((c (char-after)))
          (cond ((eq c ?\\) (forward-char 1))
                ((eq c ?%) (end-of-line))
                ((memq c '(?\{ ?\[)) (setq depth (1+ depth)))
                ((memq c '(?\} ?\])) (setq depth (1- depth)))
                ((and (eq c ?\;) (= depth 0)) (setq end (1+ (point))))))
        (forward-char 1))
      end)))

(defun texpresso-view--statements (from to)
  "The objects' nodes between FROM and TO of this buffer: ((BEG . END) …)."
  (save-excursion
    (goto-char from)
    (let (statements)
      (while (re-search-forward "\\\\node[ \t\n]*\\[tv[],]" to t)
        (let* ((beg (match-beginning 0))
               (end (texpresso-view--statement-end beg to)))
          (when end
            (push (cons beg end) statements)
            (goto-char end))))
      (nreverse statements))))

(defun texpresso-view--statement (k)
  "Object K's node in the source: (BUFFER BEG END) with markers, or nil."
  (pcase-let ((`(,buf ,beg ,end) (texpresso-view--frame)))
    (when buf
      (with-current-buffer buf
        (let* ((layer (texpresso-view--layer beg end))
               (statement (and layer (nth (1- k) (texpresso-view--statements
                                                  (car layer) (cdr layer))))))
          (when statement
            (list buf (copy-marker (car statement)) (copy-marker (cdr statement) t))))))))

(defun texpresso-view--number (v)
  "V rounded to half a unit, as written in the source."
  (let ((r (/ (round (* v 2)) 2.0)))
    (if (= r (ftruncate r)) (format "%d" (truncate r)) (format "%.1f" r))))

(defun texpresso-view--set-place (statement x y &optional w)
  "Put the node of STATEMENT, (BUFFER BEG END), at X Y, and W wide if W."
  (pcase-let ((`(,buf ,beg ,end) statement))
    (with-current-buffer buf
      (save-excursion
        (goto-char beg)
        (when (re-search-forward "\\_<at[ \t\n]*(\\([^,()]*\\),\\([^()]*\\))" end t)
          (let ((new (format "at (%s,%s)" (texpresso-view--number x) (texpresso-view--number y))))
            (unless (equal (match-string 0) new)
              (replace-match new t t))))
        (when w
          (goto-char beg)
          (when (re-search-forward "width=\\([0-9.]+\\)\\\\tvu" end t)
            (let ((new (texpresso-view--number (max 1 w))))
              (unless (equal (match-string 1) new)
                (replace-match new t t nil 1)))))))))

(defun texpresso-view--source-box (statement box)
  "STATEMENT's place and width as its source says, with BOX's height scaled.
BOX, (X Y W H), is what TeX reported, which lags behind an edit just
made: (X Y W H) from the source, or BOX where it says nothing."
  (pcase-let ((`(,buf ,beg ,end) statement)
              (`(,bx ,by ,bw ,bh) box))
    (with-current-buffer buf
      (save-excursion
        (goto-char beg)
        (let* ((x bx) (y by) (w bw))
          (when (re-search-forward "\\_<at[ \t\n]*(\\([^,()]*\\),\\([^()]*\\))" end t)
            (setq x (or (ignore-errors (string-to-number (match-string 1))) x)
                  y (or (ignore-errors (string-to-number (match-string 2))) y)))
          (goto-char beg)
          (when (re-search-forward "width=\\([0-9.]+\\)\\\\tvu" end t)
            (setq w (string-to-number (match-string 1))))
          (list x y w (if (and bw (> bw 0)) (* bh (/ w bw)) bh)))))))

(defun texpresso-view--resized (box corner mx my)
  "BOX, (X Y W H), with its CORNER dragged to MX MY: its aspect kept.
The new width is the larger of the two the mouse asks for, across and
down."
  (pcase-let* ((`(,x ,y ,w ,h) box)
               (ratio (if (and (> w 0) (> h 0)) (/ h w) 1))
               (across (if (memq corner '(nw sw)) (- (+ x w) mx) (- mx x)))
               (down (/ (if (memq corner '(nw ne)) (- (+ y h) my) (- my y)) ratio))
               (nw (max 2 across down))
               (nh (* nw ratio)))
    (list (if (memq corner '(nw sw)) (- (+ x w) nw) x)
          (if (memq corner '(nw ne)) (- (+ y h) nh) y)
          nw nh)))

(defun texpresso-view--gui-page-p (win)
  "Non-nil if WIN shows the page as an image, in a graphical frame."
  (and (eq win (texpresso-view--window))
       (not (texpresso-view--tty-p win))
       texpresso-view--png))

(defun texpresso-view--event-units (event)
  "Where on the slide the mouse EVENT is, in slide units: (X . Y), or nil."
  (let* ((posn (event-start event))
         (xy (posn-object-x-y posn)))
    (when (and xy (texpresso-view--gui-page-p (posn-window posn)))
      (let ((u (texpresso-view--units-per-pixel)))
        (cons (* (car xy) u) (* (cdr xy) u))))))

(defun texpresso-view-mouse-down (event)
  "Select, move or resize the object under the mouse EVENT on the page.
A press on an object selects it; a drag moves it, or, from a corner of
the object selected, resizes it, its aspect kept; the source follows as
it moves, and the whole drag is one undo.  A double click shows its node
in the source, to edit it.  A press elsewhere takes the selection away,
and the click or drag that follows does what it did before: jump to the
source, copy text."
  (interactive "e")
  (let* ((posn (event-start event))
         (win (posn-window posn))
         (at (texpresso-view--event-units event))
         (hit (and at (texpresso-view--hit (car at) (cdr at)))))
    (when at
      (setq texpresso-view--anchor at))
    (cond
     (hit
      (select-window win)
      (texpresso-view--drag event (car hit) (cadr hit)))
     (texpresso-view--selected
      (setq texpresso-view--selected nil)
      (texpresso-view--draw-page)))))

(defun texpresso-view--drag (event k corner)
  "Drag object K from the press EVENT until the release, by CORNER if any."
  (let* ((statement (texpresso-view--statement k))
         (box (and statement
                   (texpresso-view--source-box statement (cdr (assq k (texpresso-view--objects))))))
         (posn (event-start event))
         (win (posn-window posn))
         (xy (posn-x-y posn))
         (oxy (posn-object-x-y posn))
         (origin (cons (- (car xy) (car oxy)) (- (cdr xy) (cdr oxy))))
         (u (texpresso-view--units-per-pixel))
         (x0 (* (car oxy) u))
         (y0 (* (cdr oxy) u))
         (double (memq 'double (event-modifiers event)))
         (mouse-fine-grained-tracking t)
         (group (and statement (prepare-change-group (car statement))))
         moved new ev)
    (setq texpresso-view--selected k)
    (texpresso-view--draw-page)
    (when group
      (activate-change-group group))
    (unwind-protect
        (progn
          (track-mouse
            (while (mouse-movement-p (setq ev (read-event)))
              (let* ((p (event-start ev))
                     (pxy (posn-x-y p)))
                (when (and box statement pxy (eq (posn-window p) win))
                  (let ((mx (* (- (car pxy) (car origin)) u))
                        (my (* (- (cdr pxy) (cdr origin)) u)))
                    (setq moved (or moved (> (abs (- mx x0)) 0.3) (> (abs (- my y0)) 0.3)))
                    (when moved
                      (setq new (if corner
                                    (texpresso-view--resized box corner mx my)
                                  (list (+ (nth 0 box) (- mx x0)) (+ (nth 1 box) (- my y0))
                                        (nth 2 box) (nth 3 box))))
                      (setq texpresso-view--outline new)
                      (texpresso-view--draw-page)
                      ;; one change at a time: the next once its page came
                      (when (or (not texpresso-view--waiting)
                                (> (- (float-time) texpresso-view--waiting) 0.3))
                        (setq texpresso-view--waiting (float-time))
                        (texpresso-view--set-place statement (nth 0 new) (nth 1 new)
                                                   (and corner (nth 2 new))))))))))
          (when new
            (texpresso-view--set-place statement (nth 0 new) (nth 1 new)
                                       (and corner (nth 2 new)))))
      (when group
        (accept-change-group group)
        (undo-amalgamate-change-group group))
      (setq texpresso-view--outline nil)
      (texpresso-view--draw-page))
    (cond
     ((and double (not moved))
      (texpresso-view-edit-object))
     ((not moved)
      (message "%s" (substitute-command-keys
                     "Drag to move, a corner to resize; \\<texpresso-view-mode-map>\\[texpresso-view-edit-object] edit, \\[texpresso-view-delete-object] delete, \\[texpresso-view-duplicate-object] duplicate, \\[texpresso-view-deselect] done"))))))

(defun texpresso-view--selected-statement ()
  "The node of the object selected: (BUFFER BEG END), or a user error."
  (or (and texpresso-view--selected
           (texpresso-view--statement texpresso-view--selected))
      (user-error "No object selected on the page")))

(defun texpresso-view-deselect ()
  "Take the selection away from the object selected."
  (interactive)
  (setq texpresso-view--selected nil)
  (texpresso-view--draw-page))

(defun texpresso-view-edit-object ()
  "Show the node of the object selected in the source window, to edit it.
The cursor goes into its text: a text box's words, a picture's
\\includegraphics."
  (interactive)
  (pcase-let ((`(,buf ,beg ,end) (texpresso-view--selected-statement))
              (win (texpresso-view--source-window)))
    (unless (window-live-p win)
      (user-error "No source window"))
    (set-window-buffer win buf)
    (select-window win)
    (goto-char beg)
    (if (re-search-forward "\\_<at[ \t\n]*([^()]*)[ \t\n]*{" end t)
        (when (looking-at "\\(Text\\)}")
          (texpresso-view--select-placeholder (point) (match-end 1)))
      (goto-char beg))))

(defvar-local texpresso-view--placeholder-text nil
  "The placeholder word selected in this buffer, that typing replaces.")

(defun texpresso-view--select-placeholder (beg end)
  "Select the placeholder word from BEG to END: what is typed first replaces it.
Point goes to BEG."
  (goto-char beg)
  (push-mark end t t)
  (setq texpresso-view--placeholder-text (buffer-substring-no-properties beg end))
  (add-hook 'pre-command-hook #'texpresso-view--placeholder nil t))

(defun texpresso-view--placeholder ()
  "Delete the placeholder word selected before the first thing typed."
  (remove-hook 'pre-command-hook #'texpresso-view--placeholder t)
  (when (and (symbolp this-command)
             ;; self-insert-command, AUCTeX's TeX-insert-quote and the like, yank
             (string-match-p "insert\\|yank" (symbol-name this-command))
             (use-region-p)
             (equal (buffer-substring-no-properties (region-beginning) (region-end))
                    texpresso-view--placeholder-text))
    (delete-region (region-beginning) (region-end))))

(defun texpresso-view--nudge (dx dy)
  "Move the object selected by DX DY slide units."
  (let* ((statement (texpresso-view--selected-statement))
         (box (texpresso-view--source-box
               statement (cdr (assq texpresso-view--selected (texpresso-view--objects))))))
    (when (nth 0 box)
      (texpresso-view--set-place statement (+ (nth 0 box) dx) (+ (nth 1 box) dy)))))

(defun texpresso-view--arrow (dx dy page)
  "Move the object selected by DX DY, or turn PAGE pages if none is."
  (if texpresso-view--selected
      (texpresso-view--nudge dx dy)
    (texpresso-view--turn page)))

(defun texpresso-view-left (n)
  "Move the object selected left half a unit, N with a prefix; or turn back."
  (interactive "p")
  (texpresso-view--arrow (- (* 0.5 n)) 0 -1))

(defun texpresso-view-right (n)
  "Move the object selected right half a unit, N with a prefix; or turn on."
  (interactive "p")
  (texpresso-view--arrow (* 0.5 n) 0 1))

(defun texpresso-view-up (n)
  "Move the object selected up half a unit (N with a prefix), or turn back."
  (interactive "p")
  (texpresso-view--arrow 0 (- (* 0.5 n)) -1))

(defun texpresso-view-down (n)
  "Move the object selected down half a unit (N with a prefix), or turn the page."
  (interactive "p")
  (texpresso-view--arrow 0 (* 0.5 n) 1))

(defun texpresso-view-resize (factor)
  "Make the object selected FACTOR times as wide, its top left corner in place."
  (let* ((statement (texpresso-view--selected-statement))
         (box (texpresso-view--source-box
               statement (cdr (assq texpresso-view--selected (texpresso-view--objects))))))
    (when (nth 2 box)
      (texpresso-view--set-place statement (nth 0 box) (nth 1 box) (* factor (nth 2 box))))))

(defun texpresso-view-larger ()
  "Make the object selected a tenth wider, its aspect kept."
  (interactive)
  (texpresso-view-resize 1.1))

(defun texpresso-view-smaller ()
  "Make the object selected a tenth narrower, its aspect kept."
  (interactive)
  (texpresso-view-resize (/ 1 1.1)))

(defun texpresso-view--statement-region (statement)
  "STATEMENT's whole lines: (BEG . END), END after its newline."
  (pcase-let ((`(,buf ,beg ,end) statement))
    (with-current-buffer buf
      (save-excursion
        (cons (progn (goto-char beg) (line-beginning-position))
              (progn (goto-char end) (min (point-max) (1+ (line-end-position)))))))))

(defun texpresso-view-delete-object ()
  "Delete the object selected from its slide, onto the kill ring."
  (interactive)
  (let* ((statement (texpresso-view--selected-statement))
         (region (texpresso-view--statement-region statement)))
    (with-current-buffer (car statement)
      (kill-region (car region) (cdr region)))
    (setq texpresso-view--selected nil)
    (texpresso-view--draw-page)
    (message "Deleted (C-y in the source brings it back)")))

(defun texpresso-view-backspace ()
  "Delete the object selected, or turn back a page if none is."
  (interactive)
  (if texpresso-view--selected
      (texpresso-view-delete-object)
    (texpresso-view-previous)))

(defun texpresso-view-duplicate-object ()
  "Put a copy of the object selected over it, a little lower and to the right.
The copy is selected."
  (interactive)
  (let* ((statement (texpresso-view--selected-statement))
         (region (texpresso-view--statement-region statement))
         (box (texpresso-view--source-box
               statement (cdr (assq texpresso-view--selected (texpresso-view--objects)))))
         copy)
    (with-current-buffer (car statement)
      (save-excursion
        (let ((text (buffer-substring (car region) (cdr region))))
          (goto-char (cdr region))
          (unless (bolp) (insert "\n"))
          (setq copy (list (current-buffer) (point-marker) nil))
          (insert text)
          (setcar (cddr copy) (point-marker)))))
    (when (nth 0 box)
      (texpresso-view--set-place copy (+ (nth 0 box) 3) (+ (nth 1 box) 3)))
    (setq texpresso-view--selected (1+ texpresso-view--selected))))

(defun texpresso-view--swap-statements (k l)
  "Swap the nodes of objects K and L of the page on display, K before L."
  (let ((a (texpresso-view--statement k))
        (b (texpresso-view--statement l)))
    (when (and a b)
      (with-current-buffer (car a)
        (let ((ta (buffer-substring (nth 1 a) (nth 2 a)))
              (tb (buffer-substring (nth 1 b) (nth 2 b))))
          (save-excursion
            (goto-char (nth 1 b))
            (delete-region (nth 1 b) (nth 2 b))
            (insert ta)
            (goto-char (nth 1 a))
            (delete-region (nth 1 a) (nth 2 a))
            (insert tb))))
      t)))

(defun texpresso-view-raise-object ()
  "Bring the object selected one step forward, over the next one."
  (interactive)
  (texpresso-view--selected-statement)
  (when (texpresso-view--swap-statements texpresso-view--selected (1+ texpresso-view--selected))
    (setq texpresso-view--selected (1+ texpresso-view--selected))))

(defun texpresso-view-lower-object ()
  "Send the object selected one step back, under the one before."
  (interactive)
  (texpresso-view--selected-statement)
  (when (and (> texpresso-view--selected 1)
             (texpresso-view--swap-statements (1- texpresso-view--selected) texpresso-view--selected))
    (setq texpresso-view--selected (1- texpresso-view--selected))))

;;; New objects: a picture (picked, pasted or dropped) or a text box, at the
;;; last click on the slide.  The preamble's definitions and the frame's
;;; tvlayer are added the first time.

(defun texpresso-view--root-buffer ()
  "The buffer of the document's root file."
  (or (find-buffer-visiting texpresso-view--root)
      (find-file-noselect texpresso-view--root)))

(defun texpresso-view--input-files (buf)
  "The files BUF reads with \\input or \\include, that exist, in order."
  (with-current-buffer buf
    (save-excursion
      (goto-char (point-min))
      (let ((dir (file-name-directory texpresso-view--root)) files)
        (while (re-search-forward "^[ \t]*\\\\\\(?:input\\|include\\){\\([^}]+\\)}" nil t)
          (let ((file (expand-file-name (match-string 1) dir)))
            (setq file (seq-find #'file-exists-p (list (concat file ".tex") file)))
            (when (and file (not (file-directory-p file)))
              (push file files))))
        (nreverse files)))))

(defun texpresso-view--ensure-preamble ()
  "Put `texpresso-view-slides-preamble' before \\begin{document}, unless there.
Looked for in the root file and the files it reads."
  (let* ((root (texpresso-view--root-buffer))
         (buffers (cons root (mapcar (lambda (f) (or (find-buffer-visiting f) (find-file-noselect f)))
                                     (texpresso-view--input-files root))))
         (marker "% texpresso-view slides: begin"))
    (unless (seq-some (lambda (b) (with-current-buffer b
                                    (save-excursion (goto-char (point-min))
                                                    (search-forward marker nil t))))
                      buffers)
      (let ((home (seq-find (lambda (b) (with-current-buffer b
                                          (save-excursion
                                            (goto-char (point-min))
                                            (re-search-forward "^[ \t]*\\\\begin{document}" nil t))))
                            buffers)))
        (unless home
          (user-error "No \\begin{document} in %s or the files it reads"
                      (file-name-nondirectory texpresso-view--root)))
        (with-current-buffer home
          (save-excursion
            (goto-char (point-min))
            (re-search-forward "^[ \t]*\\\\begin{document}")
            (goto-char (line-beginning-position))
            (insert texpresso-view-slides-preamble)))))))

(defun texpresso-view--ensure-layer ()
  "The tvlayer of the frame on display, made if it has none: (BUFFER FROM TO)."
  (pcase-let ((`(,buf ,beg ,end) (or (texpresso-view--frame)
                                     (user-error "No frame found in the source for this page"))))
    (with-current-buffer buf
      (unless (texpresso-view--layer beg end)
        (save-excursion
          (goto-char end)
          (search-backward "\\end{frame}" beg)
          (let ((indent (buffer-substring (line-beginning-position)
                                          (save-excursion (back-to-indentation) (point)))))
            (if (looking-back "^[ \t]*" (line-beginning-position))
                (progn (goto-char (line-beginning-position))
                       (insert indent "  \\begin{tvlayer}\n" indent "  \\end{tvlayer}\n"))
              (insert "\n" indent "  \\begin{tvlayer}\n" indent "  \\end{tvlayer}\n" indent)))))
      (pcase-let* ((`(,_ ,beg2 ,end2) (texpresso-view--frame))
                   (layer (texpresso-view--layer beg2 end2)))
        (list buf (car layer) (cdr layer))))))

(defun texpresso-view--insert-object (node)
  "Add NODE, a TikZ statement, to the slide on display, over the others.
It is selected.  Returns its statement."
  (unless (process-live-p texpresso--process)
    (user-error "TeXpresso is not running"))
  ;; the frame first: the page's line is stale once the preamble's lines are in
  (let ((start (or (texpresso-view--frame-marker)
                   (user-error "No \\begin{frame} in the source holds this slide (one a macro makes?): nothing can be placed on it"))))
    (unless (seq-find (lambda (f) (and (eq (nth 0 f) (marker-buffer start))
                                       (= (nth 1 f) start)))
                      (texpresso-view--deck-frames))
      (user-error "This slide comes from a macro or the preamble (%s): nothing can be placed on it"
                  (buffer-name (marker-buffer start)))))
  (texpresso-view--ensure-preamble)
  (pcase-let ((`(,buf ,from ,to) (texpresso-view--ensure-layer)))
    (with-current-buffer buf
      (let ((count (length (texpresso-view--statements from to))))
        (save-excursion
          (goto-char to)
          (let ((indent (if (looking-back "^\\([ \t]*\\)" (line-beginning-position))
                            (match-string 1) "")))
            (goto-char (line-beginning-position))
            (insert indent "  " node "\n")))
        (setq texpresso-view--selected (1+ count))
        (texpresso-view--statement (1+ count))))))

(defun texpresso-view--place ()
  "Where a new object goes: the last click on the slide, or near its middle."
  (or texpresso-view--anchor (cons 30 20)))

(defconst texpresso-view--image-regexp "\\.\\(?:png\\|jpe?g\\|pdf\\)\\'"
  "A picture TeX can include.")

(defun texpresso-view--image-path (file)
  "FILE as the document names it: relative to its folder.
A file from outside the folder is copied into its figures/ first."
  (let* ((dir (file-name-directory texpresso-view--root))
         (relative (file-relative-name file dir)))
    (if (not (string-prefix-p ".." relative))
        relative
      (let* ((figures (expand-file-name "figures" dir))
             (target (expand-file-name (file-name-nondirectory file) figures))
             (n 1))
        (make-directory figures t)
        (while (file-exists-p target)
          (setq n (1+ n)
                target (expand-file-name (format "%s-%d.%s" (file-name-base file) n
                                                 (file-name-extension file))
                                         figures)))
        (copy-file file target)
        (file-relative-name target dir)))))

(defun texpresso-view--insert-image (file)
  "Put the picture FILE on the slide on display, at the last click."
  (let ((place (texpresso-view--place))
        (path (texpresso-view--image-path (expand-file-name file))))
    (texpresso-view--insert-object
     (format "\\node[tv] at (%s,%s) {\\includegraphics[width=30\\tvu]{%s}};"
             (texpresso-view--number (car place)) (texpresso-view--number (cdr place))
             path))
    (texpresso-view--draw-page)
    (message "Picture %s placed: drag it, or a corner of it" path)))

(defun texpresso-view-insert-image (file)
  "Put the picture FILE (PNG, JPEG or PDF) on the slide, at the last click.
A file from outside the document's folder is copied into its figures/."
  (interactive
   (list (read-file-name "Picture: " nil nil t nil
                         (lambda (f) (or (file-directory-p f)
                                         (string-match-p texpresso-view--image-regexp (downcase f)))))))
  (texpresso-view--insert-image file))

(defun texpresso-view--clipboard-png ()
  "The PNG picture on the clipboard, as bytes, or nil."
  (or (let ((data (ignore-errors (gui-get-selection 'CLIPBOARD 'image/png))))
        (and (stringp data) (string-prefix-p "\x89PNG" data) data))
      (and (executable-find "wl-paste")
           (with-temp-buffer
             (set-buffer-multibyte nil)
             (and (eq 0 (call-process "wl-paste" nil t nil "--no-newline" "--type" "image/png"))
                  (string-prefix-p "\x89PNG" (buffer-string))
                  (buffer-string))))))

(defun texpresso-view-paste-image ()
  "Put the clipboard's picture (a screenshot) on the slide, at the last click.
It is saved in the document's figures/ as pasted-DATE-TIME.png."
  (interactive)
  (let ((data (or (texpresso-view--clipboard-png)
                  (user-error "No picture on the clipboard")))
        (file (expand-file-name (format-time-string "figures/pasted-%Y%m%d-%H%M%S.png")
                                (file-name-directory texpresso-view--root))))
    (make-directory (file-name-directory file) t)
    (let ((coding-system-for-write 'no-conversion))
      (write-region data nil file nil 'silent))
    (texpresso-view--insert-image file)))

(defun texpresso-view--drop (url _action)
  "Put the picture dropped on the page, URL, where it was dropped."
  (let ((file (dnd-get-local-file-name url t)))
    (when (and file (string-match-p texpresso-view--image-regexp (downcase file)))
      (pcase-let* ((`(,frame ,x . ,y) (mouse-pixel-position))
                   (posn (and frame x (posn-at-x-y x y frame)))
                   (at (and posn (texpresso-view--event-units (list 'mouse-movement posn)))))
        (when at
          (setq texpresso-view--anchor at)))
      (texpresso-view--insert-image file)
      'private)))

(defun texpresso-view-add-text ()
  "Put a text box on the slide, at the last click, and the cursor in its text.
The word Text is selected in the source window: type over it."
  (interactive)
  (let ((place (texpresso-view--place)))
    (texpresso-view--insert-object
     (format "\\node[tv,text width=40\\tvu,align=left] at (%s,%s) {Text};"
             (texpresso-view--number (car place)) (texpresso-view--number (cdr place))))
    (texpresso-view--draw-page)
    (texpresso-view-edit-object)
    (message "Type the text in the source window: it shows on the slide as you type")))

;;; The slide strip, as Google Slides has on the left: the deck's frames in
;;; order, in the files it \inputs too, each with a small picture of its
;;; page and its title, the one on display marked.  It moves, copies and
;;; deletes whole frames in the source, and adds new ones from layouts.
;;; TeXpresso writes the small pictures (its `thumbnails' command), and
;;; typesets to the document's end while the strip is open, so that every
;;; slide has one.

(defconst texpresso-view-slides-buffer-name "*TeXpresso slides*"
  "The buffer of the slide strip.")

(defcustom texpresso-view-layouts
  '(("Title and text" . "\\begin{frame}{Title}\n  Text\n\\end{frame}\n")
    ("Title and bullets"
     . "\\begin{frame}{Title}\n  \\begin{itemize}\n  \\item Text\n  \\end{itemize}\n\\end{frame}\n")
    ("Two columns"
     . "\\begin{frame}{Title}\n  \\begin{columns}[T]\n    \\begin{column}{0.48\\textwidth}\n      Text\n    \\end{column}\n    \\begin{column}{0.48\\textwidth}\n    \\end{column}\n  \\end{columns}\n\\end{frame}\n")
    ("Title only" . "\\begin{frame}{Title}\n\\end{frame}\n")
    ("Section title" . "\\begin{frame}\n  \\centering\\Large Title\n\\end{frame}\n")
    ("Blank" . "\\begin{frame}[plain]\n\\end{frame}\n"))
  "The layouts of a new slide: (NAME . FRAME), FRAME a beamer frame's source.
Its first \"Title\", or else \"Text\", is selected for typing over."
  :type '(alist :key-type string :value-type string)
  :group 'tex)

(defface texpresso-view-current-slide
  '((t :inherit highlight :extend t))
  "The slide on display, in the slide strip."
  :group 'tex)

(defun texpresso-view--strip-window ()
  "The window of the slide strip, if any."
  (get-buffer-window texpresso-view-slides-buffer-name t))

(defun texpresso-view--input-target (name)
  "The file \\input{NAME} reads, relative to the document's folder, or nil."
  (let ((file (expand-file-name name (file-name-directory texpresso-view--root))))
    (seq-find (lambda (f) (and (file-exists-p f) (not (file-directory-p f))))
              (list (concat file ".tex") file))))

(defun texpresso-view--frame-title (beg end)
  "The title of the frame from BEG to END of this buffer, as plain text."
  (save-excursion
    (goto-char beg)
    (re-search-forward "\\\\begin{frame}" end t)
    (while (looking-at "[ \t]*\\(<[^>\n]*>\\|\\[\\)")
      (goto-char (if (equal (match-string 1) "[")
                     (or (texpresso-view--group-end (1- (match-end 0)) ?\[ ?\]) end)
                   (match-end 0))))
    (let ((title
           (cond ((looking-at "[ \t]*{")
                  (let ((from (match-end 0)))
                    (buffer-substring-no-properties
                     from (1- (or (texpresso-view--group-end (1- from) ?\{ ?\}) (1+ from))))))
                 ((re-search-forward "\\\\frametitle\\(?:<[^>]*>\\)?\\(?:\\[[^]]*\\]\\)?{" end t)
                  (let ((from (point)))
                    (buffer-substring-no-properties
                     from (1- (or (texpresso-view--group-end (1- from) ?\{ ?\}) (1+ from)))))))))
      (string-trim
       (replace-regexp-in-string
        "[ \t\n]+" " "
        (replace-regexp-in-string
         "\\\\[a-zA-Z@]+\\*?\\|[{}$~\\\\]" " " (or title "")))))))

(defun texpresso-view--group-end (pos open close)
  "After the CLOSE that ends the group OPEN at POS, or nil."
  (save-excursion
    (goto-char pos)
    (let ((depth 0) end)
      (while (and (not end) (not (eobp)))
        (let ((c (char-after)))
          (cond ((eq c ?\\) (forward-char 1))
                ((eq c open) (setq depth (1+ depth)))
                ((and (eq c close) (= (setq depth (1- depth)) 0))
                 (setq end (1+ (point))))))
        (forward-char 1))
      end)))

(defun texpresso-view--frames-of (buf depth)
  "The frames of BUF and of the files it reads, in order.
Each is (BUFFER BEG END TITLE); DEPTH counts the \\input files read to
get to BUF."
  (with-current-buffer buf
    (save-restriction
      (widen)
      (save-excursion
        (goto-char (point-min))
        ;; in the root, the slides are after \begin{document}: the frames before
        ;; it, and in the files it reads there, are macros' (\AtBeginSection)
        (when (= depth 0)
          (re-search-forward "^[ \t]*\\\\begin{document}" nil t))
        (let (frames)
          (while (re-search-forward
                  "^[ \t]*\\\\\\(?:\\(begin{frame}\\)\\|\\(?:input\\|include\\){\\([^}]+\\)}\\)" nil t)
            (if (match-beginning 1)
                (let ((beg (match-beginning 0)))
                  (when (re-search-forward "\\\\end{frame}" nil t)
                    (push (list buf beg (point) (texpresso-view--frame-title beg (point)))
                          frames)))
              (let ((file (texpresso-view--input-target (match-string 2))))
                (when (and file (< depth 5))
                  (dolist (frame (texpresso-view--frames-of
                                  (or (find-buffer-visiting file) (find-file-noselect file))
                                  (1+ depth)))
                    (push frame frames))))))
          (nreverse frames))))))

(defun texpresso-view--deck-frames ()
  "The deck's frames, in order: ((BUFFER BEG END TITLE) …)."
  (when texpresso-view--root
    (texpresso-view--frames-of (texpresso-view--root-buffer) 0)))

(defun texpresso-view--frame-index (frames buf pos)
  "The index in FRAMES of the frame of BUF that holds POS, or nil.
A page from no frame of the strip (one a macro makes) holds none."
  (seq-position frames nil (lambda (frame _)
                             (and (eq (nth 0 frame) buf)
                                  (<= (nth 1 frame) pos (nth 2 frame))))))

(defun texpresso-view--frame-pictures (frames)
  "The strip's picture of each of FRAMES: a vector of (FILE WIDTH HEIGHT) or nil.
A frame with overlays has a page for each: the last one, the frame whole."
  (let ((pictures (make-vector (length frames) nil))
        (root-dir (file-name-directory texpresso-view--root)))
    (dolist (thumb texpresso-view--thumbs)
      (pcase-let ((`(,file ,_page ,w ,h ,source ,line) thumb))
        (when (and source (file-readable-p file))
          (let ((buf (find-buffer-visiting (expand-file-name source root-dir))))
            (when buf
              (let* ((pos (with-current-buffer buf
                            (save-restriction
                              (widen)
                              (save-excursion
                                (goto-char (point-min))
                                (forward-line (1- line))
                                (point)))))
                     (i (texpresso-view--frame-index frames buf pos)))
                (when i
                  (aset pictures i (list file w h)))))))))
    pictures))

(defun texpresso-view--slide-picture (picture)
  "The strip's image of PICTURE, (FILE WIDTH HEIGHT), in a thin grey border."
  (pcase-let* ((`(,file ,w ,h) picture)
               (data (with-temp-buffer
                       (set-buffer-multibyte nil)
                       (insert-file-contents-literally file)
                       (buffer-string))))
    (if (not (image-type-available-p 'svg))
        (create-image data 'png t :scale 1.0 :margin 2 :width w :height h)
      (let ((svg (svg-create (+ w 2) (+ h 2))))
        (svg-embed svg data "image/png" t :x 1 :y 1 :width w :height h)
        (svg-rectangle svg 0.5 0.5 (+ w 1) (+ h 1) :fill "none" :stroke "#9aa0a6" :stroke-width 1)
        (svg-image svg :scale 1.0 :margin 2)))))

(defun texpresso-view--strip-draw ()
  "Draw the slide strip again: the frames, their pictures, the one on display."
  (setq texpresso-view--strip-timer nil)
  (let ((buf (get-buffer texpresso-view-slides-buffer-name))
        (win (texpresso-view--strip-window)))
    (when (and buf texpresso-view--root)
      (let* ((frames (texpresso-view--deck-frames))
             (pictures (texpresso-view--frame-pictures frames))
             (current (texpresso-view--frame-marker))
             (images (and win (display-images-p (window-frame win))))
             (n 0)
             here)
        (dolist (frame texpresso-view--strip-frames)
          (set-marker (nth 1 frame) nil))
        (setq texpresso-view--strip-frames
              (mapcar (lambda (f)
                        (list (nth 0 f)
                              (with-current-buffer (nth 0 f) (copy-marker (nth 1 f)))
                              (nth 2 f) (nth 3 f)))
                      frames))
        (with-current-buffer buf
          (let ((inhibit-read-only t)
                (line (and win (with-selected-window win (line-number-at-pos)))))
            (erase-buffer)
            (dolist (frame texpresso-view--strip-frames)
              (let ((start (point))
                    (picture (aref pictures n))
                    (on (and current (eq (marker-buffer current) (nth 0 frame))
                             (= (marker-position current) (marker-position (nth 1 frame))))))
                (insert (propertize (format "%3d " (1+ n)) 'face 'shadow))
                (if (and images picture)
                    (progn
                      (insert-image (texpresso-view--slide-picture picture))
                      (insert "\n    "))
                  (unless images (insert " ")))
                (insert (let ((title (nth 3 frame)))
                          (if (string-empty-p title) "(no title)" title))
                        "\n")
                (put-text-property start (point) 'texpresso-view-slide n)
                (when on
                  (add-face-text-property start (point) 'texpresso-view-current-slide)
                  (setq here start))
                (setq n (1+ n))))
            (cond
             (here
              (goto-char here)
              (when win
                (set-window-point win here)
                (unless (pos-visible-in-window-p here win)
                  (with-selected-window win (recenter)))))
             (line
              (goto-char (point-min))
              (forward-line (1- line))))))))))

(defun texpresso-view--strip-schedule ()
  "Draw the slide strip again soon, if it is open."
  (when (and (texpresso-view--strip-window) (not (timerp texpresso-view--strip-timer)))
    (setq texpresso-view--strip-timer (run-with-timer 0.3 nil #'texpresso-view--strip-draw))))

(defun texpresso-view--thumbs-request ()
  "Ask TeXpresso for the strip's pictures, every page's, at the strip's width."
  (setq texpresso-view--thumbs-timer nil)
  (let ((win (texpresso-view--strip-window)))
    (when (and win (process-live-p texpresso--process)
               (display-images-p (window-frame win))
               (not (and texpresso-view--thumbs-pending
                         (< (- (float-time) texpresso-view--thumbs-pending) 10))))
      (unless (and texpresso-view--thumbs-dir (file-directory-p texpresso-view--thumbs-dir))
        (setq texpresso-view--thumbs-dir (make-temp-file "texpresso-view-slides" t)))
      (let ((width (max 60 (min 260 (- (window-body-width win t)
                                       (* 6 (frame-char-width (window-frame win))))))))
        (setq texpresso-view--thumbs-new nil
              texpresso-view--thumbs-pending (float-time))
        (texpresso--send 'thumbnails texpresso-view--thumbs-dir width width)))))

(defun texpresso-view--thumbs-schedule (&optional delay)
  "Ask for the strip's pictures again after DELAY seconds (1) of quiet."
  (when (texpresso-view--strip-window)
    (when (timerp texpresso-view--thumbs-timer)
      (cancel-timer texpresso-view--thumbs-timer))
    (setq texpresso-view--thumbs-timer
          (run-with-timer (or delay 1.0) nil #'texpresso-view--thumbs-request))))

(defun texpresso-view--thumbs-done (_count finished)
  "TeXpresso sent the strip's pictures: draw them.
If TeX is not FINISHED, ask again."
  (setq texpresso-view--thumbs (nreverse texpresso-view--thumbs-new)
        texpresso-view--thumbs-new nil
        texpresso-view--thumbs-pending nil)
  (texpresso-view--strip-draw)
  (unless finished
    (texpresso-view--thumbs-schedule 1.0)))

(defun texpresso-view--thumbs-stop ()
  "Stop the strip's pictures: TeX goes back to typesetting what is on display."
  (when (timerp texpresso-view--thumbs-timer)
    (cancel-timer texpresso-view--thumbs-timer))
  (when (timerp texpresso-view--strip-timer)
    (cancel-timer texpresso-view--strip-timer))
  (when (process-live-p texpresso--process)
    (texpresso--send 'thumbnails "" 0 0))
  (when (and texpresso-view--thumbs-dir (file-directory-p texpresso-view--thumbs-dir))
    (delete-directory texpresso-view--thumbs-dir t))
  (dolist (frame texpresso-view--strip-frames)
    (set-marker (nth 1 frame) nil))
  (setq texpresso-view--thumbs-dir nil
        texpresso-view--thumbs nil
        texpresso-view--thumbs-new nil
        texpresso-view--thumbs-pending nil
        texpresso-view--thumbs-timer nil
        texpresso-view--strip-timer nil
        texpresso-view--strip-frames nil))

(defun texpresso-view-slides ()
  "Show the deck's slides in a strip on the left, or close it.
Each frame, in order, with a small picture of its page and its title,
the one on display marked.  In the strip: RET or a click shows a slide,
M-up and M-down move it (a drag to another slide too), d copies it,
DEL deletes it (onto the kill ring), + adds a new one after it from a
layout (`texpresso-view-layouts'), q closes the strip."
  (interactive)
  (unless (process-live-p texpresso--process)
    (user-error "No TeXpresso view open"))
  (let ((win (texpresso-view--strip-window)))
    (if win
        (progn
          (delete-window win)
          (texpresso-view--thumbs-stop))
      (let ((buf (get-buffer-create texpresso-view-slides-buffer-name)))
        (with-current-buffer buf
          (texpresso-view-slides-mode))
        (display-buffer-in-side-window buf '((side . left) (slot . 0) (window-width . 30)
                                             (preserve-size . (t . nil))))
        (texpresso-view--strip-draw)
        (texpresso-view--thumbs-request)))))

(defun texpresso-view-slides-refresh ()
  "Draw the slide strip again, and ask TeXpresso for its pictures."
  (interactive)
  (texpresso-view--strip-draw)
  (setq texpresso-view--thumbs-pending nil)
  (texpresso-view--thumbs-request))

(defun texpresso-view--slide-at (&optional pos)
  "The index of the strip's slide at POS (point), or a user error."
  (or (get-text-property (or pos (point)) 'texpresso-view-slide)
      (user-error "No slide here")))

(defun texpresso-view--show-frame (i)
  "Show the strip's frame I: its page, and its source in the source window."
  (pcase-let ((`(,buf ,beg . ,_) (nth i texpresso-view--strip-frames)))
    (when (and buf (marker-buffer beg))
      (let ((line (with-current-buffer buf
                    (save-excursion
                      (goto-char beg)
                      ;; beamer typesets a frame at its \end{frame}: SyncTeX knows that line
                      (re-search-forward "\\\\end{frame}" nil t)
                      (line-number-at-pos nil t))))
            (win (texpresso-view--source-window)))
        (texpresso--send 'synctex-forward (buffer-file-name buf) line)
        (when (window-live-p win)
          (set-window-buffer win buf)
          (set-window-point win beg)
          (set-window-start win beg))))))

(defun texpresso-view-slides-show ()
  "Show the slide at point on the page."
  (interactive)
  (texpresso-view--show-frame (texpresso-view--slide-at)))

(defun texpresso-view-slides-click (event)
  "Show the slide clicked in EVENT on the page."
  (interactive "e")
  (mouse-set-point event)
  (texpresso-view-slides-show))

(defun texpresso-view-slides-next ()
  "Show the next slide of the strip."
  (interactive)
  (let ((i (texpresso-view--slide-at)))
    (when (< (1+ i) (length texpresso-view--strip-frames))
      (texpresso-view--show-frame (1+ i)))))

(defun texpresso-view-slides-previous ()
  "Show the previous slide of the strip."
  (interactive)
  (let ((i (texpresso-view--slide-at)))
    (when (> i 0)
      (texpresso-view--show-frame (1- i)))))

(defun texpresso-view--chunk (i)
  "The source of the strip's frame I with the lines that go with it.
\(BUFFER BEG END): from the comment and setting lines right above its
\\begin{frame} (no blank line, \\section or other frame between) to the
end of its \\end{frame} line, and one blank line after it."
  (pcase-let ((`(,buf ,beg . ,_) (nth i texpresso-view--strip-frames)))
    (with-current-buffer buf
      (save-excursion
        ;; its end found again: what was typed since the strip was drawn moved it
        (goto-char beg)
        (re-search-forward "\\\\end{frame}")
        (forward-line 1)
        (when (looking-at "[ \t]*\n")
          (forward-line 1))
        (let ((to (point)))
          (goto-char beg)
          (beginning-of-line)
          (while (and (not (bobp))
                      (save-excursion
                        (forward-line -1)
                        (not (or (looking-at "[ \t]*$")
                                 (looking-at "[ \t]*\\\\\\(?:\\(?:sub\\)*section\\|part\\|appendix\\|begin{document}\\|input\\|include\\|AtBeginSection\\)\\_>")
                                 (search-forward "\\end{frame}" (line-end-position) t)))))
            (forward-line -1))
          (list buf (point) to))))))

(defun texpresso-view--chunk-text (chunk)
  "The text of CHUNK, (BUFFER BEG END), ending with a newline."
  (pcase-let ((`(,buf ,beg ,end) chunk))
    (let ((text (with-current-buffer buf (buffer-substring beg end))))
      (if (string-suffix-p "\n" text) text (concat text "\n")))))

(defun texpresso-view--insert-at (buf pos text)
  "Insert TEXT at POS of BUF, a line of its own."
  (with-current-buffer buf
    (save-excursion
      (goto-char pos)
      (unless (bolp) (insert "\n"))
      (insert text))))

(defun texpresso-view--move-frame (i j)
  "Move the strip's frame I to where frame J is: before it if J < I, else after."
  (let* ((chunk (texpresso-view--chunk i))
         (target (texpresso-view--chunk j))
         (text (texpresso-view--chunk-text chunk))
         (at (with-current-buffer (nth 0 target)
               (copy-marker (if (< j i) (nth 1 target) (nth 2 target))))))
    (with-current-buffer (nth 0 chunk)
      (delete-region (nth 1 chunk) (nth 2 chunk)))
    (texpresso-view--insert-at (marker-buffer at) at text)
    (set-marker at nil)
    (texpresso-view--strip-draw)
    (texpresso-view--show-frame j)
    (texpresso-view--strip-goto j)))

(defun texpresso-view--strip-goto (i)
  "Put the strip's point on slide I."
  (let ((buf (get-buffer texpresso-view-slides-buffer-name)))
    (when buf
      (with-current-buffer buf
        (let ((pos (text-property-any (point-min) (point-max) 'texpresso-view-slide i)))
          (when pos
            (goto-char pos)
            (let ((win (texpresso-view--strip-window)))
              (when win (set-window-point win pos)))))))))

(defun texpresso-view-slides-move-up ()
  "Move the slide at point before the one above it."
  (interactive)
  (let ((i (texpresso-view--slide-at)))
    (when (> i 0)
      (texpresso-view--move-frame i (1- i)))))

(defun texpresso-view-slides-move-down ()
  "Move the slide at point after the one below it."
  (interactive)
  (let ((i (texpresso-view--slide-at)))
    (when (< (1+ i) (length texpresso-view--strip-frames))
      (texpresso-view--move-frame i (1+ i)))))

(defun texpresso-view-slides-drag (event)
  "Move the slide where the drag EVENT starts to where it ends."
  (interactive "e")
  (let ((from (posn-point (event-start event)))
        (to (posn-point (event-end event))))
    (when (and from to (eq (posn-window (event-end event)) (posn-window (event-start event))))
      (let ((i (texpresso-view--slide-at from))
            (j (texpresso-view--slide-at to)))
        (unless (= i j)
          (texpresso-view--move-frame i j))))))

(defun texpresso-view-slides-duplicate ()
  "Put a copy of the slide at point after it."
  (interactive)
  (let* ((i (texpresso-view--slide-at))
         (chunk (texpresso-view--chunk i)))
    (texpresso-view--insert-at (nth 0 chunk) (nth 2 chunk)
                               (texpresso-view--chunk-text chunk))
    (texpresso-view--strip-draw)
    (texpresso-view--show-frame (1+ i))
    (texpresso-view--strip-goto (1+ i))))

(defun texpresso-view-slides-delete ()
  "Delete the slide at point, onto the kill ring.
\\[yank] in a source brings it back."
  (interactive)
  (let* ((i (texpresso-view--slide-at))
         (chunk (texpresso-view--chunk i)))
    (with-current-buffer (nth 0 chunk)
      (kill-region (nth 1 chunk) (nth 2 chunk)))
    (texpresso-view--strip-draw)
    (let ((n (length texpresso-view--strip-frames)))
      (when (> n 0)
        (texpresso-view--show-frame (min i (1- n)))
        (texpresso-view--strip-goto (min i (1- n)))))
    (message "Slide %d deleted (C-y in a source brings it back)" (1+ i))))

(defun texpresso-view-slides-new (layout)
  "Add a slide after the one at point, from LAYOUT.
LAYOUT is a name in `texpresso-view-layouts'.
Its title (or first text) is selected in the source window: type over it."
  (interactive
   (list (completing-read "Layout: " texpresso-view-layouts nil t nil nil
                          (caar texpresso-view-layouts))))
  (let* ((frame (cdr (assoc layout texpresso-view-layouts)))
         (frames texpresso-view--strip-frames)
         (i (if frames
                (or (get-text-property (point) 'texpresso-view-slide) (1- (length frames)))
              (user-error "No frame in the deck to put a slide after")))
         (chunk (texpresso-view--chunk i))
         (end (nth 2 chunk))
         (buf (nth 0 chunk))
         (blank (with-current-buffer buf
                  (save-excursion (goto-char end) (forward-line -1) (looking-at "[ \t]*$"))))
         (start (with-current-buffer buf (copy-marker end))))
    (texpresso-view--insert-at buf end (concat frame (if blank "\n" "")))
    (texpresso-view--strip-draw)
    (texpresso-view--show-frame (1+ i))
    (texpresso-view--strip-goto (1+ i))
    (let ((win (texpresso-view--source-window)))
      (when (window-live-p win)
        (select-window win)
        (set-window-buffer win buf)
        (goto-char start)
        (when (re-search-forward "\\_<\\(Title\\|Text\\)\\_>"
                                 (save-excursion (re-search-forward "\\\\end{frame}" nil t)) t)
          (texpresso-view--select-placeholder (match-beginning 0) (match-end 0)))))
    (set-marker start nil)))

(defvar texpresso-view-slides-mode-map
  (make-sparse-keymap)
  "Keys of the slide strip.")

(defun texpresso-view--define-slides-keys (map)
  "Give MAP the keys of the slide strip."
  (define-key map (kbd "RET") #'texpresso-view-slides-show)
  (define-key map [mouse-1] #'texpresso-view-slides-click)
  (define-key map [down-mouse-1] #'ignore)
  (define-key map [drag-mouse-1] #'texpresso-view-slides-drag)
  (define-key map (kbd "n") #'texpresso-view-slides-next)
  (define-key map (kbd "p") #'texpresso-view-slides-previous)
  (define-key map (kbd "<down>") #'texpresso-view-slides-next)
  (define-key map (kbd "<up>") #'texpresso-view-slides-previous)
  (define-key map (kbd "M-<up>") #'texpresso-view-slides-move-up)
  (define-key map (kbd "M-<down>") #'texpresso-view-slides-move-down)
  (define-key map (kbd "d") #'texpresso-view-slides-duplicate)
  (define-key map (kbd "DEL") #'texpresso-view-slides-delete)
  (define-key map (kbd "<delete>") #'texpresso-view-slides-delete)
  (define-key map (kbd "+") #'texpresso-view-slides-new)
  (define-key map (kbd "a") #'texpresso-view-slides-new)
  (define-key map (kbd "g") #'texpresso-view-slides-refresh)
  (define-key map (kbd "q") #'texpresso-view-slides)
  map)

(texpresso-view--define-slides-keys texpresso-view-slides-mode-map)

(define-derived-mode texpresso-view-slides-mode special-mode "Slides"
  "The deck's slides, beside TeXpresso's page.
\\{texpresso-view-slides-mode-map}"
  (setq-local cursor-type nil)
  (setq-local truncate-lines t)
  (setq-local display-line-numbers nil))

(defun texpresso-view--define-keys (map)
  "Give MAP the keys of the page window.
Run at each load, so that a package loaded again brings its new keys to
the map a running Emacs already has."
  (define-key map [mouse-1] #'texpresso-view-click)
  (define-key map [drag-mouse-1] #'texpresso-view-select)
  (define-key map [down-mouse-1] #'texpresso-view-mouse-down)
  (define-key map (kbd "n") #'texpresso-view-next)
  (define-key map (kbd "p") #'texpresso-view-previous)
  (define-key map (kbd "<next>") #'texpresso-view-next)
  (define-key map (kbd "<prior>") #'texpresso-view-previous)
  ;; the arrows turn pages, or move the object selected
  (define-key map (kbd "<down>") #'texpresso-view-down)
  (define-key map (kbd "<right>") #'texpresso-view-right)
  (define-key map (kbd "<up>") #'texpresso-view-up)
  (define-key map (kbd "<left>") #'texpresso-view-left)
  (define-key map (kbd "SPC") #'texpresso-view-next)
  (define-key map (kbd "DEL") #'texpresso-view-backspace)
  (define-key map [wheel-down] #'texpresso-view-wheel)
  (define-key map [wheel-up] #'texpresso-view-wheel)
  (define-key map (kbd "q") #'quit-window)
  ;; objects on the slide
  (define-key map (kbd "<delete>") #'texpresso-view-delete-object)
  (define-key map (kbd "d") #'texpresso-view-duplicate-object)
  (define-key map (kbd "RET") #'texpresso-view-edit-object)
  (define-key map (kbd "<escape>") #'texpresso-view-deselect)
  (define-key map (kbd "]") #'texpresso-view-raise-object)
  (define-key map (kbd "[") #'texpresso-view-lower-object)
  (define-key map (kbd "+") #'texpresso-view-larger)
  (define-key map (kbd "=") #'texpresso-view-larger)
  (define-key map (kbd "-") #'texpresso-view-smaller)
  (define-key map (kbd "t") #'texpresso-view-add-text)
  (define-key map (kbd "i") #'texpresso-view-insert-image)
  (define-key map (kbd "C-y") #'texpresso-view-paste-image)
  (define-key map (kbd "s") #'texpresso-view-slides)
  map)

(defvar texpresso-view-mode-map (make-sparse-keymap)
  "Keys of the page window.")

(texpresso-view--define-keys texpresso-view-mode-map)

(define-derived-mode texpresso-view-mode special-mode "TeXpresso"
  "TeXpresso's page, beside the source.
\\{texpresso-view-mode-map}"
  (setq-local cursor-type nil)
  (setq-local display-line-numbers nil)
  (setq-local mode-line-process nil)
  ;; a picture dropped from a file manager goes on the slide
  (setq-local dnd-protocol-alist
              (cons (cons "^file:" #'texpresso-view--drop) dnd-protocol-alist)))

;;;###autoload
(defun texpresso-view (&optional whole)
  "Show TeXpresso's live view of this LaTeX or Texinfo file on the right.
With a prefix argument WHOLE, TeXpresso typesets AUCTeX's `TeX-master'
instead, the whole document this file is part of, and the page follows
this file as it does its own.  Run it again in the same buffer, with the
same argument, to close the view and stop TeXpresso; in another LaTeX
buffer, or with the other argument, it shows that instead."
  (interactive "P")
  (let ((root (texpresso-view--root whole)))
    (if (and (eq (current-buffer) texpresso-view--source)
             (equal root texpresso-view--root)
             (process-live-p texpresso--process)
             (texpresso-view--window))
        (texpresso-view--stop)
      (texpresso-view--start root))))

(defvar TeX-master)
(declare-function TeX-master-file "tex" (&optional extension nondirectory ask))

(defun texpresso-view--root (whole)
  "The file TeXpresso is to typeset: this buffer's, or with WHOLE its master."
  (unless (buffer-file-name)
    (user-error "TeXpresso view: this buffer has no file"))
  (if (or (not whole) (and (boundp 'TeX-master) (eq TeX-master t)))
      ;; TeX-master t: the file is its own master
      (buffer-file-name)
    (unless (and (fboundp 'TeX-master-file) (boundp 'TeX-master) (stringp TeX-master))
      (user-error "TeXpresso view: this buffer has no TeX-master (AUCTeX's) to typeset"))
    (let ((master (expand-file-name (TeX-master-file t))))
      (unless (file-exists-p master)
        (user-error "TeXpresso view: the TeX-master %s does not exist" master))
      master)))

(defvar pdf-view-scroll-sync-mode)
(declare-function pdf-view-scroll-sync-mode "pdf-view-scroll-sync")

(defconst texpresso-view--texinfo-regexp "\\.\\(?:texi\\|texinfo\\|txi\\)\\'"
  "A Texinfo file's name: TeXpresso typesets one with plain XeTeX's format.")

(defvar texpresso-view--synced nil
  "The buffers given `texpresso-sync-mode' by the view, to take it back.")

(defun texpresso-view--texinfo-sync ()
  "Have TeXpresso follow this buffer's edits if it visits a Texinfo file.
texpresso.el follows only the buffers whose mode derives from `tex-mode',
which `texinfo-mode' does not: the others need `texpresso-sync-mode'."
  (when (and buffer-file-name
             (string-match-p texpresso-view--texinfo-regexp buffer-file-name)
             (not (derived-mode-p 'tex-mode))
             (not texpresso-sync-mode))
    (texpresso-sync-mode 1)
    (push (current-buffer) texpresso-view--synced)))

(defun texpresso-view--texinfo-unsync ()
  "Take `texpresso-sync-mode' back from the buffers the view gave it to."
  (remove-hook 'find-file-hook #'texpresso-view--texinfo-sync)
  (dolist (buf texpresso-view--synced)
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (texpresso-sync-mode -1))))
  (setq texpresso-view--synced nil))

;;; Edits made on disk, by another program (a script, an AI agent), reach
;;; the page too.  A file open in Emacs is reverted, which runs the change
;;; hooks with `buffer-file-name' nil: texpresso.el would send TeXpresso the
;;; text with no file, which it drops, and the page would wait for the next
;;; edit typed there.  So the hooks are skipped while a revert runs, and the
;;; buffer is sent whole once it is done.  A file not open in Emacs TeXpresso
;;; reads again only when told to: the document's folders are watched, and a
;;; change there tells it (`rescan'); it rereads the files it read that
;;; changed, but for those open from Emacs, whose buffer it keeps.

(defconst texpresso-view-watch-limit 100
  "The most folders watched: the root's folder, then its subfolders.")

(defvar texpresso-view--watches nil
  "The file notification watches on the document's folders.")

(defvar texpresso-view--rescan-timer nil
  "The timer that tells TeXpresso to read the disk again.")

(defun texpresso-view--reverting-p (&rest _)
  "Non-nil while Emacs reloads the current buffer from its file."
  (symbol-value (if (boundp 'revert-buffer-in-progress)
                    'revert-buffer-in-progress
                  'revert-buffer-in-progress-p)))

(advice-add 'texpresso--before-change :before-until #'texpresso-view--reverting-p)
(advice-add 'texpresso--after-change :before-until #'texpresso-view--reverting-p)

(defun texpresso-view--reverted ()
  "Send TeXpresso the whole buffer, reloaded from its file.
As texpresso.el does when a buffer is first edited: its state names the
file, the process and the process's marker, so the next edit is sent as
a change."
  (when (and buffer-file-name (texpresso--enabled-p))
    (setq texpresso--state (list buffer-file-name texpresso--process
                                 (process-get texpresso--process 'marker)))
    (texpresso--send 'open buffer-file-name
                     (buffer-substring-no-properties (point-min) (point-max)))))

(add-hook 'after-revert-hook #'texpresso-view--reverted)

(defun texpresso-view--folders (dir)
  "DIR and its subfolders but hidden ones, at most `texpresso-view-watch-limit'."
  (let ((todo (list (file-name-as-directory dir))) folders)
    (while (and todo (< (length folders) texpresso-view-watch-limit))
      (let ((d (pop todo)))
        (push d folders)
        (dolist (sub (ignore-errors (directory-files d t "\\`[^.]" t)))
          (when (and (file-directory-p sub) (not (file-symlink-p sub)))
            (setq todo (append todo (list (file-name-as-directory sub))))))))
    (nreverse folders)))

(defun texpresso-view--disk-changed (event)
  "Tell TeXpresso to read the disk again, after the file change EVENT.
Once for a burst of changes, 0.3 s after the last; Emacs's own
lock, auto-save and backup files are left out."
  (pcase-let ((`(,_ ,action ,file . ,_) event))
    (when (and (memq action '(created changed renamed))
               (stringp file)
               (not (string-match-p "\\`\\.?#\\|~\\'" (file-name-nondirectory file))))
      (when (timerp texpresso-view--rescan-timer)
        (cancel-timer texpresso-view--rescan-timer))
      (setq texpresso-view--rescan-timer
            (run-with-timer 0.3 nil
                            (lambda ()
                              (setq texpresso-view--rescan-timer nil)
                              (when (process-live-p texpresso--process)
                                (texpresso--send 'rescan))))))))

(defun texpresso-view--watch (root)
  "Watch the folder of ROOT and its subfolders for files changed on disk."
  (texpresso-view--unwatch)
  (dolist (dir (texpresso-view--folders (file-name-directory (expand-file-name root))))
    (let ((watch (ignore-errors
                   (file-notify-add-watch dir '(change) #'texpresso-view--disk-changed))))
      (when watch
        (push watch texpresso-view--watches)))))

(defun texpresso-view--unwatch ()
  "Stop watching the document's folders."
  (mapc #'file-notify-rm-watch texpresso-view--watches)
  (setq texpresso-view--watches nil)
  (when (timerp texpresso-view--rescan-timer)
    (cancel-timer texpresso-view--rescan-timer))
  (setq texpresso-view--rescan-timer nil))

(defun texpresso-view--stop ()
  "Close the page's window and stop TeXpresso."
  (let ((win (texpresso-view--window)))
    (when (and win (terminal-parameter (frame-terminal (window-frame win))
                                       'texpresso-view-cell-asked))
      (texpresso-view--cell-forget (frame-terminal (window-frame win)))))
  (let ((win (texpresso-view--window)))
    (when (and win (not (one-window-p t)))
      (delete-window win)))
  (when (process-live-p texpresso--process)
    (kill-process texpresso--process)
    ;; ended before its files are deleted, so no page is written after
    (let ((end (+ (float-time) 0.5)))
      (while (and (process-live-p texpresso--process) (< (float-time) end))
        (accept-process-output texpresso--process 0.02))))
  (texpresso-view--delete-files)
  (when (buffer-live-p texpresso-view--source)
    (with-current-buffer texpresso-view--source
      (texpresso-mode -1)))
  (texpresso-view--texinfo-unsync)
  (texpresso-view--unwatch)
  (let ((strip (texpresso-view--strip-window)))
    (when strip (delete-window strip)))
  (texpresso-view--thumbs-stop)
  (when (get-buffer texpresso-view-slides-buffer-name)
    (kill-buffer texpresso-view-slides-buffer-name))
  (when (timerp texpresso-view--scroll-timer)
    (cancel-timer texpresso-view--scroll-timer))
  (when (timerp texpresso-view--errors-timer)
    (cancel-timer texpresso-view--errors-timer))
  (when (buffer-live-p texpresso-view--log)
    (kill-buffer texpresso-view--log))
  (setq texpresso-view--log nil
        texpresso-view--log-known nil
        texpresso-view--locations nil
        texpresso-view--errors-timer nil
        texpresso-view--stop-since nil)
  (setq texpresso-view--source nil
        texpresso-view--root nil
        texpresso-view--source-window nil
        texpresso-view--scroll-timer nil
        texpresso-view--page nil
        texpresso-view--turn nil)
  (when (get-buffer texpresso-view-buffer-name)
    (kill-buffer texpresso-view-buffer-name))
  (when (timerp texpresso-view--sixel-idle-timer)
    (cancel-timer texpresso-view--sixel-idle-timer))
  (when (timerp texpresso-view--sixel-timer)
    (cancel-timer texpresso-view--sixel-timer))
  (texpresso-view--tty-watch-stop)
  (texpresso-view--cell-stop)
  (when (frame-live-p (car texpresso-view--sixel-drawn))
    (redraw-frame (car texpresso-view--sixel-drawn)))
  ;; nil would be the selected frame's terminal, which a graphical one is not
  (when (and texpresso-view--sixel-held (terminal-live-p texpresso-view--sixel-held))
    (send-string-to-terminal "\e[?2026l" texpresso-view--sixel-held))
  (setq texpresso-view--sixel nil
        texpresso-view--sixel-drawn nil
        texpresso-view--sixel-timer nil
        texpresso-view--sixel-idle-timer nil
        texpresso-view--sixel-dirty nil
        texpresso-view--sixel-again nil
        texpresso-view--sixel-around nil
        texpresso-view--sixel-repair nil
        texpresso-view--sixel-held nil)
  (setq texpresso-view--size nil
        texpresso-view--png nil
        texpresso-view--page-source nil
        texpresso-view--selected nil
        texpresso-view--outline nil
        texpresso-view--anchor nil
        texpresso-view--waiting nil
        texpresso-view--frame-start nil)
  (message "TeXpresso view closed"))

(defun texpresso-view--start (root)
  "Start TeXpresso on ROOT (this file or its master), the page to the right.
TeXpresso opens no window of its own: it draws with SDL's offscreen driver
and writes the page on display as a PNG that the window shows.  Its reruns
are turned on: after a pause, if the .aux file changed, it typesets again
with the previous pass's references, as a second pdflatex pass would
\(beamer's total slide count, the table of contents, \\ref).  In this
buffer `pdf-view-scroll-sync-mode' is turned off, so that saving does not
also compile with latexmk."
  (unless (or (display-images-p) (texpresso-view--sixel-terminal-p))
    (user-error "TeXpresso view needs a graphical frame, or a terminal that shows Sixel pictures"))
  (let ((source (current-buffer))
        (process-environment (append '("SDL_VIDEO_DRIVER=offscreen"
                                       "SDL_VIDEODRIVER=offscreen")
                                     process-environment)))
    (setq texpresso-view--size nil)
    (when (and (buffer-live-p texpresso-view--source)
               (not (eq texpresso-view--source source)))
      (with-current-buffer texpresso-view--source
        (texpresso-mode -1)))
    (setq texpresso-view--source source
          texpresso-view--root root
          texpresso-view--page nil
          texpresso-view--turn nil)
    (when (bound-and-true-p pdf-view-scroll-sync-mode)
      (pdf-view-scroll-sync-mode -1))
    (texpresso-view--log-reset)
    ;; a Texinfo manual: its buffers, and its @include files once opened
    (texpresso-view--texinfo-unsync)
    (when (string-match-p texpresso-view--texinfo-regexp root)
      (dolist (buf (buffer-list))
        (with-current-buffer buf
          (texpresso-view--texinfo-sync)))
      (add-hook 'find-file-hook #'texpresso-view--texinfo-sync))
    (unless (timerp texpresso-view--sixel-idle-timer)
      (setq texpresso-view--sixel-idle-timer
            (run-with-idle-timer 0.5 t #'texpresso-view--sixel-idle)))
    (texpresso root)
    (when (process-live-p texpresso--process)
      (texpresso--send 'rerun t)
      (texpresso-view--watch root))
    (let ((buf (get-buffer-create texpresso-view-buffer-name))
          (win (or (texpresso-view--window)
                   (split-window (selected-window) nil 'right))))
      (with-current-buffer buf
        (texpresso-view-mode)
        ;; global-display-line-numbers-mode turns them on once the mode is
        ;; set: their gutter pushed the page right and cut it off
        (when (bound-and-true-p display-line-numbers-mode)
          (display-line-numbers-mode -1)))
      (set-window-buffer win buf)
      (set-window-dedicated-p win t)
      (select-window (get-buffer-window source))
      (setq texpresso-view--source-window (selected-window))
      (texpresso-view--send-size))))

(add-hook 'window-size-change-functions #'texpresso-view--send-size)

(provide 'texpresso-view)
;;; texpresso-view.el ends here
