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
;; Slides with the mouse, as in Google Slides: on a Beamer deck a toolbar
;; over the page (undo, redo, a text box, a picture from your computer, from
;; a panel of recent pictures or pasted, duplicate, delete, front, back,
;; the slide strip, a new slide), a right-click menu on the slide and a
;; Slides menu in the menu bar.  A click selects an object, a drag moves
;; it, its eight handles resize it, and the source follows as it moves (one
;; undo).  Keys do some of it: i a picture where you last clicked (C-y
;; pastes, or drop a file), t a text box, the arrows nudge, + and -
;; resize, d copies, DEL deletes, RET shows it in the source, ] and [
;; bring it forward and back.  An object is a TikZ node in the frame's
;; tvlayer, centred at a place given from the slide's top left corner in
;; hundredths of its width: plain LaTeX, defined once before
;; \begin{document}.  Shapes and lines come from the toolbar too; a round
;; handle turns an object; the format bar under the toolbar sets fill,
;; border, weight, dash, text colour, size, bold, italic, alignment and
;; opacity; a double click types an object's text on the slide.  Shift and
;; a click, or a frame dragged on an empty spot, select several, which move
;; and change together; Arrange aligns, centres, spreads and groups them,
;; and makes them appear at a later click; a dragged object snaps to
;; guides.  A picture is cropped by its handles (a double click), and
;; tables come from the Shape menu.  The slide menu gives a slide a transition, the deck a theme,
;; skips a slide, and presents the deck (F5).  s opens the slide strip on the left
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
(require 'format-spec)
(require 'svg)
(require 'dnd)
(eval-when-compile (require 'cl-lib))

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

(defvar texpresso-view--palette nil
  "The colour being picked in the format bar, or nil.
One of `fill', `border', `text', `line'.")

(defvar texpresso-view--format-cache nil
  "The format bar last made, and what it was made from: (KEY . STRING).")

(defvar texpresso-view--editor nil
  "The text being typed on the slide: (FRAME BUFFER BEG END), or nil.
FRAME is its child frame, or nil; BEG and END mark the text in the source.")

(defvar texpresso-view--cropping nil
  "The picture being cropped: its number, or nil.")

(defvar texpresso-view--also nil
  "The other objects selected: (PRIMARY . NUMBERS), PRIMARY the one selected with.")

(defvar texpresso-view--outlines nil
  "The outlines drawn while several objects are dragged: boxes.")

(defvar texpresso-view--band nil
  "The frame being dragged around objects to select them: (X Y W H), or nil.")

(defvar texpresso-view--guides nil
  "The guides a dragged object snaps to: ((x . X) (y . Y)…), drawn as lines.")

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

(defvar-local texpresso-view--stop-line nil
  "The red line over the page saying TeX stopped, or nil.")

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
      (texpresso-view--header-update)
      (texpresso-view--draw-page)))))

(defun texpresso-view--draw-page ()
  "Show the page on display in its window, the object selected outlined."
  (let ((buf (get-buffer texpresso-view-buffer-name)))
    (when (and buf texpresso-view--png)
      (pcase-let ((`(,data ,width ,height) texpresso-view--png))
        (with-current-buffer buf
          (let ((inhibit-read-only t))
            (when texpresso-view--image
              (image-flush texpresso-view--image t))
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
            (when texpresso-view--stop-line
              (setq texpresso-view--stop-line nil)
              (texpresso-view--header-update)))
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
              (setq texpresso-view--stop-line
                    (propertize (replace-regexp-in-string "%" "%%" text t t)
                                'face 'error 'help-echo text))
              (texpresso-view--header-update)))))))))

(defun texpresso-view--header-update ()
  "Put the toolbar and the format bar over the page, on a Beamer deck.
The toolbar is the page window's tab line, the format bar its header
line; when TeX stopped, the header line says so instead."
  (let ((buf (get-buffer texpresso-view-buffer-name)))
    (when buf
      (with-current-buffer buf
        (let* ((deck (and (texpresso-view--deck-p) (not (texpresso-view--tty-p))))
               (tabs (and deck '(:eval (texpresso-view--toolbar))))
               (line (cond (texpresso-view--stop-line)
                           (deck '(:eval (texpresso-view--format-bar))))))
          (unless (equal tab-line-format tabs)
            (setq tab-line-format tabs))
          (unless (equal header-line-format line)
            (setq header-line-format line)))))))

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
           ;; on a slide, a press on an empty spot marks where things go
           (unless (texpresso-view--deck-p)
             (message "TeXpresso: no text there"))
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
           (unless (texpresso-view--deck-p)
             (message "TeXpresso: no source line there"))))))))

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
    texpresso-view-up texpresso-view-left texpresso-view-backspace
    texpresso-view-toolbar-click texpresso-view-context-menu texpresso-view-paste
    texpresso-view-mouse-down-add)
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
;;; slide (a picture, a text box, a shape, a line) is a TikZ node in the
;;; frame's tvlayer:
;;;
;;;   \begin{tvlayer}
;;;     \node[tv] at (25,20) {\includegraphics[width=30\tvu]{figures/a.png}};
;;;     \node[tv,tv shape=ellipse,minimum width=20\tvu,minimum height=10\tvu,
;;;           draw=blue,fill=blue!20] at (50,45) {};
;;;     \node[tv,tv line={-{Stealth},line width=1pt},minimum width=30\tvu] at (25,8) {};
;;;   \end{tvlayer}
;;;
;;; drawn over the slide when it is shipped out, centred at (x,y) from its
;;; top left corner, in hundredths of the slide's width (\tvu), whatever
;;; its aspect ratio.  A line is a node too: its length is its width, and
;;; `rotate' turns it, as it turns any object about its centre.  The
;;; definitions go once before \begin{document}
;;; (`texpresso-view-slides-preamble'), plain LaTeX and TikZ, so the deck
;;; builds with any engine.  TeX writes each object's place and size to its
;;; log, "texpresso-view: PAGE K X Y W H", its box before any rotation: the
;;; view reads them to know what is under the mouse; a drag rewrites the
;;; node's numbers in the source, and TeXpresso shows them at once.

(defconst texpresso-view-slides-preamble
  "% texpresso-view slides: begin
% What texpresso-view places on a slide with the mouse: in a frame's tvlayer,
% TikZ nodes drawn over the slide, centred at (x,y) from its top left corner,
% in hundredths of its width (\\tvu).  TeX writes each one's place and size
% to the log, which is how texpresso-view finds them on the page.
\\usepackage{tikz}
\\usetikzlibrary{arrows.meta,shapes.geometric}
\\makeatletter
\\newlength\\tvu
\\AtBeginDocument{\\setlength\\tvu{0.01\\paperwidth}}
\\newcount\\tv@n
\\tikzset{tv/.code={\\global\\advance\\tv@n by 1
    \\tikzset{anchor=center,inner sep=0pt,outer sep=0pt,name=tv@\\the\\tv@n}},
  tv line/.style={append after command={(\\tikzlastnode.west) edge[#1] (\\tikzlastnode.east)}},
  tv group/.style={},
  tv appear/.code={\\alt<#1->{}{\\tikzset{opacity=0}}},
  tv shape/.is choice,
  tv shape/rectangle/.style={shape=rectangle},
  tv shape/rounded/.style={shape=rectangle,rounded corners=1.5\\tvu},
  tv shape/ellipse/.style={shape=ellipse},
  tv shape/diamond/.style={shape=diamond},
  tv shape/triangle/.style={shape=isosceles triangle,isosceles triangle stretches,
    shape border rotate=90}}
\\NewDocumentEnvironment{tvlayer}{O{1}+b}
  {\\only<#1>{}\\AddToHookNext{shipout/foreground}{\\tv@layer{#2}}}{}
\\newcommand\\tv@layer[1]{\\global\\tv@n=0
  \\put(0,0){\\begin{tikzpicture}[x=\\tvu,y=-\\tvu,baseline=0pt]
    \\useasboundingbox (0,0) rectangle (1,1);
    #1
    \\tv@report
  \\end{tikzpicture}}}
\\newsavebox\\tv@cropbox
\\newcommand\\tvcrop[5]{\\sbox\\tv@cropbox{#5}%
  \\begin{tikzpicture}[x=\\wd\\tv@cropbox,y=\\ht\\tv@cropbox]
    \\useasboundingbox (#1,#2) rectangle ({1-#3},{1-#4});
    \\clip (#1,#2) rectangle ({1-#3},{1-#4});
    \\node[anchor=south west,inner sep=0pt,outer sep=0pt] at (0,0) {\\usebox\\tv@cropbox};
  \\end{tikzpicture}}
\\newcommand\\tv@len[2]{\\pgfpointdiff{\\pgfpointanchor{tv@\\tv@k}{#1}}%
  {\\pgfpointanchor{tv@\\tv@k}{#2}}\\pgfmathveclen{\\pgf@x}{\\pgf@y}}
\\newcommand\\tv@report{\\ifnum\\tv@n>0
  \\foreach\\tv@k in {1,...,\\the\\tv@n}{%
    \\pgfutil@ifundefined{pgf@sh@ns@tv@\\tv@k}{}{%
    \\pgfpointanchor{tv@\\tv@k}{center}%
    \\pgfmathsetmacro\\tv@x{\\pgf@x/\\tvu}\\pgfmathsetmacro\\tv@y{-\\pgf@y/\\tvu}%
    \\tv@len{west}{east}\\pgfmathsetmacro\\tv@w{\\pgfmathresult/\\tvu}%
    \\tv@len{south}{north}\\pgfmathsetmacro\\tv@h{\\pgfmathresult/\\tvu}%
    \\pgfmathsetmacro\\tv@x{\\tv@x-\\tv@w/2}\\pgfmathsetmacro\\tv@y{\\tv@y-\\tv@h/2}%
    \\typeout{texpresso-view: \\the\\ReadonlyShipoutCounter\\space\\tv@k\\space
      \\tv@x\\space\\tv@y\\space\\tv@w\\space\\tv@h}}}\\fi}
\\makeatother
% texpresso-view slides: end
"
  "What a deck needs for objects placed with the mouse.
It goes before \\begin{document}; an older block between the same two
comment lines is replaced by it.")

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

(defun texpresso-view--boxes ()
  "The objects on the page on display: ((K X Y W H ANGLE KIND) …), K from 1.
Their box before rotation as the source says, where it does (TeX's
report lags behind an edit just made), else as TeX reported it; ANGLE
in degrees counter-clockwise, KIND as `texpresso-view--kind' says."
  (let ((statements (texpresso-view--frame-statements)))
    (mapcar (lambda (object)
              (let ((statement (nth (1- (car object)) statements)))
                (cons (car object)
                      (if statement
                          (append (seq-take (or (texpresso-view--source-box statement (cdr object))
                                                (cdr object))
                                            4)
                                  (list (texpresso-view--angle statement)
                                        (texpresso-view--kind statement)))
                        (append (cdr object) (list 0 nil))))))
            (texpresso-view--objects))))

(defun texpresso-view--box ()
  "The outline to draw: the one dragged, or the object selected's, or nil.
It is (X Y W H ANGLE KIND), as in `texpresso-view--boxes'."
  (or texpresso-view--outline
      (and texpresso-view--selected
           (cdr (assq texpresso-view--selected (texpresso-view--boxes))))))

(defun texpresso-view--turned (dx dy angle)
  "DX DY turned by ANGLE degrees counter-clockwise, on a slide whose y goes down."
  (let ((r (degrees-to-radians angle)))
    (cons (+ (* dx (cos r)) (* dy (sin r)))
          (- (* dy (cos r)) (* dx (sin r))))))

(defun texpresso-view--local (box x y)
  "The point X Y of the slide in BOX's own frame: from its centre, unturned."
  (pcase-let ((`(,bx ,by ,w ,h ,a) box))
    (texpresso-view--turned (- x (+ bx (/ w 2.0))) (- y (+ by (/ h 2.0))) (- (or a 0)))))

(defun texpresso-view--global (box lx ly)
  "The point LX LY of BOX's own frame, on the slide: (X . Y)."
  (pcase-let* ((`(,bx ,by ,w ,h ,a) box)
               (p (texpresso-view--turned lx ly (or a 0))))
    (cons (+ bx (/ w 2.0) (car p)) (+ by (/ h 2.0) (cdr p)))))

(defconst texpresso-view--rotate-reach 4
  "How far over its top the rotation handle of an object is, in slide units.")

(defun texpresso-view--handles (box)
  "The handles of BOX, (X Y W H ANGLE KIND): ((HANDLE X Y) …), on the slide.
A line has its two ends, `west' and `east'; anything else eight handles,
corners first, and `rotate' over its top."
  (pcase-let* ((`(,_ ,_ ,w ,h ,_ ,kind) box)
               (a (/ w 2.0)) (b (/ h 2.0)))
    (mapcar (lambda (handle)
              (let ((p (texpresso-view--global box (nth 1 handle) (nth 2 handle))))
                (list (car handle) (car p) (cdr p))))
            (if (eq kind 'line)
                (list (list 'west (- a) 0) (list 'east a 0))
              (append
               (list (list 'nw (- a) (- b)) (list 'ne a (- b)) (list 'sw (- a) b) (list 'se a b)
                     (list 'n 0 (- b)) (list 'e a 0) (list 's 0 b) (list 'w (- a) 0))
               ;; a picture being cropped is not turned
               (unless (and texpresso-view--cropping
                            (eql texpresso-view--cropping texpresso-view--selected))
                 (list (list 'rotate 0 (- (+ b texpresso-view--rotate-reach))))))))))

(defun texpresso-view--page-image (data width height)
  "The page's image from its PNG DATA, WIDTH x HEIGHT, the selection outlined.
With an outline, an SVG that holds the PNG and draws the outline, turned
as its object is, and its handles over it; on a slide with nothing
selected, a small cross where the next object goes."
  (let* ((several (or texpresso-view--outlines
                      (let ((ks (texpresso-view--selection)))
                        (and (cdr ks)
                             (let ((boxes (texpresso-view--boxes)))
                               (delq nil (mapcar (lambda (k) (cdr (assq k boxes))) ks)))))))
         (box (and (not several) (texpresso-view--box)))
         (anchor (and (not texpresso-view--selected) (texpresso-view--deck-p)
                      texpresso-view--anchor)))
    (if (not (and (or box anchor several texpresso-view--band) (image-type-available-p 'svg)))
        (create-image data 'png t :scale 1.0 :width width :height height)
      (let ((svg (svg-create width height))
            (u (/ width 100.0))
            (color texpresso-view--outline-color))
        (svg-embed svg data "image/png" t :x 0 :y 0 :width width :height height)
        (dolist (b several)
          (when b
            (pcase-let ((`(,_ ,_ ,w ,h) b))
              (svg-polygon svg (mapcar (lambda (c)
                                         (let ((p (texpresso-view--global b (car c) (cdr c))))
                                           (cons (* (car p) u) (* (cdr p) u))))
                                       (list (cons (- (/ w 2.0)) (- (/ h 2.0)))
                                             (cons (/ w 2.0) (- (/ h 2.0)))
                                             (cons (/ w 2.0) (/ h 2.0))
                                             (cons (- (/ w 2.0)) (/ h 2.0))))
                           :fill "none" :stroke color :stroke-width 2))))
        (when texpresso-view--band
          (pcase-let ((`(,x ,y ,w ,h) texpresso-view--band))
            (svg-rectangle svg (* x u) (* y u) (* w u) (* h u)
                           :fill color :fill-opacity 0.1 :stroke color :stroke-width 1
                           :stroke-dasharray "4 3")))
        (dolist (g texpresso-view--guides)
          (if (eq (car g) 'x)
              (svg-line svg (* (cdr g) u) 0 (* (cdr g) u) height :stroke "#e91e63" :stroke-width 1)
            (svg-line svg 0 (* (cdr g) u) width (* (cdr g) u) :stroke "#e91e63" :stroke-width 1)))
        (cond
         (several)
         (box
          (pcase-let* ((`(,_ ,_ ,w ,h ,_ ,kind) box)
                       (handles (texpresso-view--handles box)))
            (unless (eq kind 'line)
              (svg-polygon svg (mapcar (lambda (c)
                                         (let ((p (texpresso-view--global box (car c) (cdr c))))
                                           (cons (* (car p) u) (* (cdr p) u))))
                                       (list (cons (- (/ w 2.0)) (- (/ h 2.0)))
                                             (cons (/ w 2.0) (- (/ h 2.0)))
                                             (cons (/ w 2.0) (/ h 2.0))
                                             (cons (- (/ w 2.0)) (/ h 2.0))))
                           :fill "none" :stroke color :stroke-width 2)
              (let ((top (assq 'n handles)) (knob (assq 'rotate handles)))
                (when knob
                  (svg-line svg (* (nth 1 top) u) (* (nth 2 top) u) (* (nth 1 knob) u) (* (nth 2 knob) u)
                            :stroke color :stroke-width 1.5)))
              ;; a picture being cropped: all of it, dashed
              (when (and texpresso-view--cropping (eql texpresso-view--cropping texpresso-view--selected))
                (let ((statement (nth (1- texpresso-view--selected) (texpresso-view--frame-statements))))
                  (when statement
                    (svg-polygon svg (mapcar (lambda (p) (cons (* (car p) u) (* (cdr p) u)))
                                             (texpresso-view--crop-ghost box (texpresso-view--crop statement)))
                                 :fill "none" :stroke "#5f6368" :stroke-width 1
                                 :stroke-dasharray "5 3")))))
            (dolist (handle handles)
              (if (memq (car handle) '(rotate west east))
                  (svg-circle svg (* (nth 1 handle) u) (* (nth 2 handle) u) 5
                              :fill (if (eq (car handle) 'rotate) color "white")
                              :stroke color :stroke-width 1.5)
                (svg-rectangle svg (- (* (nth 1 handle) u) 4) (- (* (nth 2 handle) u) 4) 8 8
                               :fill (if (eql texpresso-view--cropping texpresso-view--selected)
                                         "black" "white")
                               :stroke color :stroke-width 1.5)))))
         (anchor
          (let ((ax (* (car anchor) u)) (ay (* (cdr anchor) u)))
            (svg-line svg (- ax 6) ay (+ ax 6) ay :stroke color :stroke-width 1.5)
            (svg-line svg ax (- ay 6) ax (+ ay 6) :stroke color :stroke-width 1.5))))
        (svg-image svg :scale 1.0)))))

(defun texpresso-view--hit (x y)
  "The object at X Y on the slide, the topmost: (K HANDLE), or nil.
HANDLE is one of `nw', `n', `ne', `e', `se', `s', `sw', `w', `rotate',
or a line's `west' or `east', for a handle of the object selected; nil
inside an object."
  (let* ((r (min 2.0 (max 0.8 (* 6 (texpresso-view--units-per-pixel)))))
         (boxes (texpresso-view--boxes))
         ;; several selected show no handles
         (selected (and (not (cdr (texpresso-view--selection)))
                        (cdr (assq texpresso-view--selected boxes))))
         (handle (and selected
                      (seq-find (lambda (c) (and (<= (abs (- x (nth 1 c))) r)
                                                 (<= (abs (- y (nth 2 c))) r)))
                                (texpresso-view--handles selected)))))
    (if handle
        (list texpresso-view--selected (car handle))
      (let (hit)
        (dolist (object boxes)
          (pcase-let* ((`(,k ,_ ,_ ,w ,h) object)
                       (p (texpresso-view--local (cdr object) x y)))
            ;; a line, or a box a line high, can still be caught
            (when (and (<= (abs (car p)) (max (/ w 2.0) r))
                       (<= (abs (cdr p)) (max (/ h 2.0) r)))
              (setq hit (list k nil)))))
        hit))))

(defvar texpresso-view--frame-start nil
  "The \\begin{frame} of the page on display: (SOURCE MARKER PAGE).
SOURCE is the `texpresso-view--page-source' it was found from, for page
PAGE: the marker follows the edits made until the next page comes.")

(defun texpresso-view--frame-marker ()
  "A marker at the \\begin{frame} of the page on display, or nil.
A page drawn again before TeX has seen the last edit may come with a line
the edit has moved out of its frame: the frame found for the same page
before is kept then."
  (let ((cached texpresso-view--frame-start))
    (if (and cached (eq (car cached) texpresso-view--page-source)
             (marker-buffer (nth 1 cached)))
        (nth 1 cached)
      (or (texpresso-view--find-frame)
          (and cached (eql (nth 2 cached) texpresso-view--page)
               (marker-buffer (nth 1 cached))
               (nth 1 cached))))))

(defun texpresso-view--find-frame ()
  "A marker at the \\begin{frame} holding the page on display's line, or nil."
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
                            (list texpresso-view--page-source marker texpresso-view--page))
                      marker)))))))))))

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

(defun texpresso-view--frame-statements ()
  "The objects' nodes on the page on display: ((BUFFER BEG END) …), in order."
  (pcase-let ((`(,buf ,beg ,end) (texpresso-view--frame)))
    (when buf
      (with-current-buffer buf
        (let ((layer (texpresso-view--layer beg end)))
          (and layer
               (mapcar (lambda (s) (list buf (car s) (cdr s)))
                       (texpresso-view--statements (car layer) (cdr layer)))))))))

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

(defconst texpresso-view--at-regexp "\\_<at[ \t\n]*(\\([^,()]*\\),\\([^()]*\\))"
  "A node's place in the source, its centre: at (X,Y).")

(defconst texpresso-view--keys
  '((width . "[[,][ \t\n]*\\(width\\)=")
    (height . "[[,][ \t\n]*\\(height\\)=")
    (text-width . "\\(text width\\)=")
    (min-width . "\\(minimum width\\)=")
    (min-height . "\\(minimum height\\)="))
  "Where a node gives each of its sizes: the key before its NUMBER\\tvu.
A picture's width and height are \\includegraphics's; a text box's width
its text width; a shape's or a line's its minimum width and height.")

(defun texpresso-view--kind (statement)
  "What STATEMENT, (BUFFER BEG END), puts on the slide.
One of `picture', `line', `shape' or `text'."
  (pcase-let ((`(,buf ,beg ,end) statement))
    (with-current-buffer buf
      (save-excursion
        (goto-char beg)
        (cond ((search-forward "\\includegraphics" end t) 'picture)
              ((progn (goto-char beg) (search-forward "tv line" end t)) 'line)
              ((progn (goto-char beg) (search-forward "tv shape" end t)) 'shape)
              (t 'text))))))

(defun texpresso-view--key-value (statement key)
  "The size STATEMENT gives KEY (see `texpresso-view--keys'), or nil."
  (pcase-let ((`(,buf ,beg ,end) statement))
    (with-current-buffer buf
      (save-excursion
        (goto-char beg)
        (when (re-search-forward (concat (cdr (assq key texpresso-view--keys))
                                         "\\(-?[0-9.]+\\)\\\\tvu")
                                 end t)
          (string-to-number (match-string 2)))))))

(defun texpresso-view--set-key (statement key value &optional after)
  "Make STATEMENT give KEY the size VALUE, when it gives KEY a size.
With AFTER, a key it lacks is added after the size it gives AFTER."
  (pcase-let ((`(,buf ,beg ,end) statement)
              (new (texpresso-view--number (max 1 value))))
    (with-current-buffer buf
      (save-excursion
        (goto-char beg)
        (cond
         ((re-search-forward (concat (cdr (assq key texpresso-view--keys))
                                     "\\(-?[0-9.]+\\)\\\\tvu")
                             end t)
          (unless (equal (match-string 2) new)
            (replace-match new t t nil 2)))
         ((and after
               (progn (goto-char beg)
                      (re-search-forward (concat (cdr (assq after texpresso-view--keys))
                                                 "-?[0-9.]+\\\\tvu")
                                         end t)))
          (insert (format ",%s=%s\\tvu"
                          (pcase key ('min-height "minimum height") ('min-width "minimum width")
                                 ('text-width "text width") (_ (symbol-name key)))
                          new))))))))

(defun texpresso-view--centre (statement)
  "STATEMENT's place in the source, the centre of its object: (X . Y), or nil."
  (pcase-let ((`(,buf ,beg ,end) statement))
    (with-current-buffer buf
      (save-excursion
        (goto-char beg)
        (when (re-search-forward texpresso-view--at-regexp end t)
          (let ((x (ignore-errors (string-to-number (match-string 1))))
                (y (ignore-errors (string-to-number (match-string 2)))))
            (and x y (cons x y))))))))

(defun texpresso-view--source-box (statement box)
  "STATEMENT's box, (X Y W H), as its source gives it.
BOX is what TeX reported, which lags behind an edit just made: the
source has the last word on the centre and on the sizes it writes down;
a text box's height, and a picture's when only its width is written,
come from BOX, scaled with the width.  Nil when neither knows the size."
  (pcase-let* ((`(,_ ,_ ,bw ,bh) box)
               (kind (texpresso-view--kind statement))
               (centre (texpresso-view--centre statement))
               ;; a cropped picture shows a part of its width and height
               (`(,cl ,cb ,cr ,ct) (if (eq kind 'picture) (texpresso-view--crop statement) '(0 0 0 0)))
               (w (let ((kw (texpresso-view--key-value
                             statement (pcase kind ('picture 'width) ('text 'text-width) (_ 'min-width)))))
                    (if kw (* kw (- 1 cl cr)) bw)))
               (h (pcase kind
                    ('picture (or (let ((kh (texpresso-view--key-value statement 'height)))
                                    (and kh (* kh (- 1 cb ct))))
                                  (and bh bw w (> bw 0) (* bh (/ w bw)))))
                    ('text (or bh (texpresso-view--key-value statement 'min-height)))
                    (_ (or (texpresso-view--key-value statement 'min-height) bh 0)))))
    (if (and centre w h)
        (list (- (car centre) (/ w 2.0)) (- (cdr centre) (/ h 2.0)) w h)
      box)))

(defun texpresso-view--set-box (statement box &optional handle)
  "Put STATEMENT's object in BOX, (X Y W H): its centre in the middle.
With HANDLE, the handle it was resized by, its size too: a picture
dragged by a side, or already stretched, gets a height of its own; a
text box dragged by its top or bottom a minimum height."
  (pcase-let ((`(,x ,y ,w ,h) box))
    (pcase-let ((`(,buf ,beg ,end) statement))
      (with-current-buffer buf
        (save-excursion
          (goto-char beg)
          (when (re-search-forward texpresso-view--at-regexp end t)
            (let ((new (format "at (%s,%s)" (texpresso-view--number (+ x (/ w 2.0)))
                               (texpresso-view--number (+ y (/ h 2.0))))))
              (unless (equal (match-string 0) new)
                (replace-match new t t)))))))
    (let ((angle (nth 4 box)))
      (when (and angle (/= angle (texpresso-view--angle statement)))
        (texpresso-view--put-option statement "rotate"
                                    (and (/= angle 0) (texpresso-view--number angle)))))
    (when (and handle (not (eq handle 'rotate)))
      (pcase (texpresso-view--kind statement)
        ('picture
         ;; a cropped picture's width and height are those of all of it
         (pcase-let ((`(,cl ,cb ,cr ,ct) (texpresso-view--crop statement)))
           (texpresso-view--set-key statement 'width (/ w (max 0.05 (- 1 cl cr))))
           (texpresso-view--set-key statement 'height (/ h (max 0.05 (- 1 cb ct)))
                                    (and (memq handle '(n e s w)) 'width))))
        ('text
         (texpresso-view--set-key statement 'text-width w)
         (texpresso-view--set-key statement 'min-height h
                                  (and (memq handle '(n s)) 'text-width)))
        (_
         (texpresso-view--set-key statement 'min-width w)
         (texpresso-view--set-key statement 'min-height h)
         (texpresso-view--set-key statement 'text-width
                                  (texpresso-view--shape-text-width
                                   (texpresso-view--option statement "tv shape") w)))))))

(defun texpresso-view--shape-text-width (shape width)
  "The text width that fits in a SHAPE WIDTH wide, as TikZ sizes it.
TikZ makes a shape large enough to hold its text's box: an ellipse
encloses it, so its box is the ellipse's width over the square root of
two; a diamond's or a triangle's, half of it."
  (max 1 (pcase shape
           ("ellipse" (- (/ width (sqrt 2)) 1))
           ((or "diamond" "triangle") (- (/ width 2.0) 1))
           (_ (- width 2)))))

(defun texpresso-view--resized (box handle mx my &optional aspect)
  "BOX, (X Y W H), with its HANDLE dragged to MX MY, the opposite side still.
HANDLE is one of `nw', `n', `ne', `e', `se', `s', `sw', `w'.  With ASPECT,
a corner keeps BOX's aspect: the larger of the two sizes the mouse asks
for wins."
  (pcase-let* ((`(,x ,y ,w ,h) box)
               (left (memq handle '(nw w sw)))
               (right (memq handle '(ne e se)))
               (top (memq handle '(nw n ne)))
               (bottom (memq handle '(sw s se)))
               (nw (cond (left (- (+ x w) mx)) (right (- mx x)) (t w)))
               (nh (cond (top (- (+ y h) my)) (bottom (- my y)) (t h))))
    (when (and aspect (or left right) (or top bottom) (> w 0) (> h 0))
      (let ((s (max (/ nw w) (/ nh h))))
        (setq nw (* w s) nh (* h s))))
    (setq nw (max 1 nw) nh (max 1 nh))
    (list (if left (- (+ x w) nw) x) (if top (- (+ y h) nh) y) nw nh)))

(defun texpresso-view--place-dragged (statement box handle crop)
  "Write STATEMENT's object dragged by HANDLE into BOX; with CROP, cropped so.
A crop keeps the picture's size: only its centre moves."
  (if crop
      (progn (texpresso-view--set-crop statement crop)
             (texpresso-view--set-box statement box))
    (texpresso-view--set-box statement box handle)))

(defun texpresso-view--dragged (box handle mx my x0 y0 aspect)
  "BOX, (X Y W H ANGLE KIND), after a drag by HANDLE from X0 Y0 to MX MY.
No HANDLE moves it; `rotate' turns it about its centre; a line's `west'
or `east' moves that end, the other one still; the others resize it in
its own frame, the opposite side still, a picture's corners keeping its
aspect with ASPECT.  An angle within 4 degrees of a multiple of 15 is
taken to it."
  (pcase-let ((`(,x ,y ,w ,h ,a ,kind) box))
    (cl-flet ((snap (deg) (let ((s (* 15 (round deg 15))))
                            (if (< (abs (- deg s)) 4) s deg))))
      (pcase handle
        ('nil (list (+ x (- mx x0)) (+ y (- my y0)) w h a kind))
        ('rotate
         (let ((c (texpresso-view--global box 0 0)))
           (list x y w h
                 (snap (radians-to-degrees (atan (- (car c) mx) (- (cdr c) my))))
                 kind)))
        ((or 'west 'east)
         (let* ((other (texpresso-view--global box (if (eq handle 'east) (- (/ w 2.0)) (/ w 2.0)) 0))
                (dx (- mx (car other))) (dy (- my (cdr other)))
                (len (max 1 (sqrt (+ (* dx dx) (* dy dy)))))
                ;; the line's angle points from its west end to its east end
                (deg (snap (radians-to-degrees (if (eq handle 'east) (atan (- dy) dx)
                                                 (atan dy (- dx))))))
                (dir (texpresso-view--turned 1 0 deg))
                (cx (+ (car other) (* (if (eq handle 'east) 0.5 -0.5) len (car dir))))
                (cy (+ (cdr other) (* (if (eq handle 'east) 0.5 -0.5) len (cdr dir)))))
           (list (- cx (/ len 2.0)) (- cy (/ h 2.0)) len h deg kind)))
        (_
         (let* ((p (texpresso-view--local box mx my))
                (local (texpresso-view--resized (list (- (/ w 2.0)) (- (/ h 2.0)) w h)
                                                handle (car p) (cdr p) aspect))
                (c (texpresso-view--global box (+ (nth 0 local) (/ (nth 2 local) 2.0))
                                           (+ (nth 1 local) (/ (nth 3 local) 2.0)))))
           (list (- (car c) (/ (nth 2 local) 2.0)) (- (cdr c) (/ (nth 3 local) 2.0))
                 (nth 2 local) (nth 3 local) a kind)))))))

(defun texpresso-view--resize-handle (statement handle)
  "The handle a drag of HANDLE resizes STATEMENT's object by.
A text box's height is its text's: its corners change its width only."
  (if (eq (texpresso-view--kind statement) 'text)
      (pcase handle ((or 'nw 'sw) 'w) ((or 'ne 'se) 'e) (_ handle))
    handle))

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
A press on an object selects it; a drag moves it, or, from a handle of
the object selected, resizes it (a picture's corners keep its aspect);
the source follows as it moves, and the whole drag is one undo.  A
press on one of several selected, or of a group, drags them all.  A
double click types its text on the slide.  A press elsewhere takes the
selection away and marks where the next object goes; on a slide, a drag
from there frames the objects to select; a click, or elsewhere a drag,
does what it did before: jump to the source, copy text."
  (interactive "e")
  (let* ((posn (event-start event))
         (win (posn-window posn))
         (at (texpresso-view--event-units event))
         (hit (and at (texpresso-view--hit (car at) (cdr at)))))
    (texpresso-view-text-done)
    (unless (and hit (eql (car hit) texpresso-view--cropping))
      (setq texpresso-view--cropping nil))
    (when at
      (setq texpresso-view--anchor at))
    (cond
     ((and hit (cadr hit))
      (select-window win)
      (texpresso-view--drag event (car hit) (cadr hit)))
     (hit
      (select-window win)
      (let* ((now (texpresso-view--selection))
             (ks (if (and (cdr now) (memq (car hit) now))
                     now
                   (texpresso-view--group-of (car hit)))))
        (if (cdr ks)
            (progn
              (texpresso-view--select (cons (car hit) (delq (car hit) (copy-sequence ks))))
              (texpresso-view--drag-all event ks))
          (texpresso-view--drag event (car hit) nil))))
     (t
      (texpresso-view--select nil)
      (texpresso-view--draw-page)
      (when (and at (texpresso-view--deck-p))
        (select-window win)
        (texpresso-view--band event))))))

(defun texpresso-view--drag-all (event ks)
  "Drag the objects KS together from the press EVENT until the release."
  (let* ((statements (mapcar #'texpresso-view--statement ks))
         (boxes (mapcar (lambda (k) (cdr (assq k (texpresso-view--boxes)))) ks))
         (posn (event-start event))
         (win (posn-window posn))
         (xy (posn-x-y posn))
         (oxy (posn-object-x-y posn))
         (origin (cons (- (car xy) (car oxy)) (- (cdr xy) (cdr oxy))))
         (u (texpresso-view--units-per-pixel))
         (x0 (* (car oxy) u))
         (y0 (* (cdr oxy) u))
         (mouse-fine-grained-tracking t)
         (group (and (car statements) (prepare-change-group (car (car statements)))))
         (done (make-list (length ks) (cons 0 0)))
         moved dx dy ev)
    (texpresso-view--draw-page)
    (when group
      (activate-change-group group))
    (cl-flet ((follow (p)
                (let ((pxy (posn-x-y p)))
                  (when (and pxy (eq (posn-window p) win))
                    (setq dx (- (* (- (car pxy) (car origin)) u) x0)
                          dy (- (* (- (cdr pxy) (cdr origin)) u) y0)
                          moved (or moved (> (abs dx) 0.3) (> (abs dy) 0.3))))))
              (place ()
                ;; each one moved by what it still lacks of the whole move
                (setq done (seq-mapn (lambda (statement d)
                                       (when statement
                                         (texpresso-view--shift statement (- dx (car d)) (- dy (cdr d))))
                                       (cons dx dy))
                                     statements done))))
      (unwind-protect
          (progn
            (track-mouse
              (while (mouse-movement-p (setq ev (read-event)))
                (follow (event-start ev))
                (when moved
                  (setq texpresso-view--outlines
                        (mapcar (lambda (b) (and b (append (list (+ (nth 0 b) dx) (+ (nth 1 b) dy))
                                                           (nthcdr 2 b))))
                                boxes))
                  (texpresso-view--draw-page)
                  (when (or (not texpresso-view--waiting)
                            (> (- (float-time) texpresso-view--waiting) 0.3))
                    (setq texpresso-view--waiting (float-time))
                    (place)))))
            (when (and (consp ev) (memq 'drag (event-modifiers ev)))
              (follow (event-end ev)))
            (when moved
              (place)))
        (when group
          (accept-change-group group)
          (undo-amalgamate-change-group group))
        (setq texpresso-view--outlines nil)
        (texpresso-view--draw-page)))))

(defun texpresso-view--drag (event k corner)
  "Drag object K from the press EVENT until the release, by handle CORNER if any."
  (let* ((statement (texpresso-view--statement k))
         (box (and statement
                   (let ((b (texpresso-view--source-box statement
                                                        (cdr (assq k (texpresso-view--objects))))))
                     (and b (append (seq-take b 4)
                                    (list (texpresso-view--angle statement)
                                          (texpresso-view--kind statement)))))))
         (corner (and corner statement (texpresso-view--resize-handle statement corner)))
         (aspect (and statement (eq (texpresso-view--kind statement) 'picture)
                      (not (texpresso-view--key-value statement 'height))))
         (crop (and corner (eql texpresso-view--cropping k) (texpresso-view--crop statement)))
         ;; a move snaps to the other objects' edges and middles, and the slide's
         (others (and (not corner)
                      (mapcar (lambda (o) (texpresso-view--extent (cdr o)))
                              (seq-remove (lambda (o) (eql (car o) k)) (texpresso-view--boxes)))))
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
         moved new new-crop ev)
    (setq texpresso-view--selected k)
    (texpresso-view--draw-page)
    (when group
      (activate-change-group group))
    (cl-flet ((follow (p)
                ;; the place and size for the mouse at P, a position in WIN
                (let ((pxy (posn-x-y p)))
                  (when (and box statement pxy (eq (posn-window p) win))
                    (let ((mx (* (- (car pxy) (car origin)) u))
                          (my (* (- (cdr pxy) (cdr origin)) u)))
                      (setq moved (or moved (> (abs (- mx x0)) 0.3) (> (abs (- my y0)) 0.3)))
                      (when moved
                        (setq new (if crop
                                      (let ((c (texpresso-view--cropped box crop corner mx my)))
                                        (setq new-crop (cdr c))
                                        (car c))
                                    (texpresso-view--dragged box corner mx my x0 y0 aspect)))
                        (unless corner
                          (pcase-let ((`(,gx ,gy ,guides) (texpresso-view--guides-for new others)))
                            (setq new (append (list (+ (nth 0 new) gx) (+ (nth 1 new) gy))
                                              (nthcdr 2 new))
                                  texpresso-view--guides guides)))))))))
      (unwind-protect
          (progn
            (track-mouse
              (while (mouse-movement-p (setq ev (read-event)))
                (follow (event-start ev))
                (when new
                  (setq texpresso-view--outline new)
                  (texpresso-view--draw-page)
                  ;; one change at a time: the next once its page came
                  (when (or (not texpresso-view--waiting)
                            (> (- (float-time) texpresso-view--waiting) 0.3))
                    (setq texpresso-view--waiting (float-time))
                    (texpresso-view--place-dragged statement new corner new-crop)))))
            ;; the release has the last word, whether motion events came or not
            (when (and (consp ev) (memq 'drag (event-modifiers ev)))
              (follow (event-end ev)))
            (when new
              (texpresso-view--place-dragged statement new corner new-crop)))
        (when group
          (accept-change-group group)
          (undo-amalgamate-change-group group))
        (setq texpresso-view--outline nil
              texpresso-view--guides nil)
        (texpresso-view--draw-page)))
    (cond
     ((and double (not moved))
      (texpresso-view-edit-text))
     ((not moved)
      (message "Drag it to move it, a handle to resize it; right-click it for more")))))

(defun texpresso-view--selected-statement ()
  "The node of the object selected: (BUFFER BEG END), or a user error."
  (or (and texpresso-view--selected
           (texpresso-view--statement texpresso-view--selected))
      (user-error "No object selected on the page")))

(defun texpresso-view-deselect ()
  "Take the selection away from the object selected, and end cropping it."
  (interactive)
  (setq texpresso-view--selected nil
        texpresso-view--cropping nil)
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

(defun texpresso-view--shift (statement dx dy)
  "Move STATEMENT's object by DX DY slide units."
  (let ((centre (texpresso-view--centre statement)))
    (when centre
      (texpresso-view--set-box statement (list (+ (car centre) dx) (+ (cdr centre) dy) 0 0)))))

(defun texpresso-view--nudge (dx dy)
  "Move the object selected by DX DY slide units."
  (texpresso-view--shift (texpresso-view--selected-statement) dx dy))

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
  "Make the object selected FACTOR times as large, about its centre."
  (let* ((statement (texpresso-view--selected-statement))
         (box (texpresso-view--source-box
               statement (cdr (assq texpresso-view--selected (texpresso-view--objects))))))
    (pcase-let ((`(,x ,y ,w ,h) box))
      (when (and w h)
        (let ((nw (* factor w)) (nh (* factor h)))
          (texpresso-view--set-box statement
                                   (list (- (+ x (/ w 2.0)) (/ nw 2.0)) (- (+ y (/ h 2.0)) (/ nh 2.0))
                                         nw nh)
                                   'se))))))

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

(defun texpresso-view--selected-statements ()
  "The nodes of the objects selected: ((BUFFER BEG END) …), markers, in order."
  (or (delq nil (mapcar #'texpresso-view--statement (texpresso-view--selection)))
      (list (texpresso-view--selected-statement))))

(defun texpresso-view--take-out (statements)
  "Delete the nodes STATEMENTS, whole lines, and return their text, in order."
  (let ((regions (mapcar (lambda (statement)
                           (let ((r (texpresso-view--statement-region statement)))
                             (with-current-buffer (car statement)
                               (list (current-buffer) (copy-marker (car r)) (copy-marker (cdr r))))))
                         statements)))
    (prog1 (mapconcat (lambda (r) (with-current-buffer (car r)
                                    (buffer-substring (nth 1 r) (nth 2 r))))
                      regions "")
      (dolist (r regions)
        (with-current-buffer (car r)
          (delete-region (nth 1 r) (nth 2 r))
          (set-marker (nth 1 r) nil)
          (set-marker (nth 2 r) nil))))))

(defun texpresso-view-delete-object ()
  "Delete the objects selected from their slide, onto the kill ring."
  (interactive)
  (kill-new (texpresso-view--take-out (texpresso-view--selected-statements)))
  (texpresso-view--select nil)
  (texpresso-view--draw-page)
  (message "Deleted (C-y pastes it back)"))

(defun texpresso-view-backspace ()
  "Delete the object selected, or turn back a page if none is."
  (interactive)
  (if texpresso-view--selected
      (texpresso-view-delete-object)
    (texpresso-view-previous)))

(defun texpresso-view-duplicate-object ()
  "Put a copy of the object selected over it, a little lower and to the right.
The copy is selected.  Several selected are copied over all the others."
  (interactive)
  (if (cdr (texpresso-view--selection))
      (let ((texts (mapcar (lambda (statement)
                             (with-current-buffer (car statement)
                               (buffer-substring-no-properties (nth 1 statement) (nth 2 statement))))
                           (texpresso-view--selected-statements)))
            ks)
        (dolist (text texts)
          (texpresso-view--shift (texpresso-view--insert-object text) 3 3)
          (push texpresso-view--selected ks))
        (texpresso-view--select (nreverse ks))
        (texpresso-view--draw-page))
    (texpresso-view--duplicate-one)))

(defun texpresso-view--duplicate-one ()
  "Put a copy of the object selected over it, and select it."
  (let* ((statement (texpresso-view--selected-statement))
         (region (texpresso-view--statement-region statement))
         copy)
    (with-current-buffer (car statement)
      (save-excursion
        (let ((text (buffer-substring (car region) (cdr region))))
          (goto-char (cdr region))
          (unless (bolp) (insert "\n"))
          (setq copy (list (current-buffer) (point-marker) nil))
          (insert text)
          (setcar (cddr copy) (point-marker)))))
    (texpresso-view--shift copy 3 3)
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
Looked for in the root file and the files it reads; an older block,
between the same first and last lines, is replaced."
  (let* ((root (texpresso-view--root-buffer))
         (buffers (cons root (mapcar (lambda (f) (or (find-buffer-visiting f) (find-file-noselect f)))
                                     (texpresso-view--input-files root))))
         (marker "% texpresso-view slides: begin")
         (found nil))
    (dolist (b buffers)
      (with-current-buffer b
        (save-excursion
          (save-restriction
            (widen)
            (goto-char (point-min))
            (when (search-forward marker nil t)
              (setq found t)
              (let ((beg (match-beginning 0)))
                (when (search-forward "% texpresso-view slides: end" nil t)
                  (let ((end (min (point-max) (1+ (line-end-position)))))
                    (unless (equal (buffer-substring-no-properties beg end)
                                   texpresso-view-slides-preamble)
                      (goto-char beg)
                      (delete-region beg end)
                      (insert texpresso-view-slides-preamble))))))))))
    (unless found
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
             (and (eq 0 (let ((coding-system-for-read 'binary))
                          (call-process "wl-paste" nil t nil "--no-newline" "--type" "image/png")))
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
  "Put a text box on the slide, at the last click, and type its text there.
The word Text is selected in the small box under it: type over it."
  (interactive)
  (let ((place (texpresso-view--place)))
    (texpresso-view--insert-object
     (format "\\node[tv,text width=40\\tvu,align=left] at (%s,%s) {Text};"
             (texpresso-view--number (car place)) (texpresso-view--number (cdr place))))
    (texpresso-view--draw-page)
    (texpresso-view-edit-text)))

(defun texpresso-view--move-to-end (front)
  "Put the objects selected over all the others, or with FRONT nil under them.
They keep their order among themselves."
  (let* ((statements (texpresso-view--selected-statements))
         (count (length statements))
         (n (length (texpresso-view--frame-statements)))
         (buf (car (car statements)))
         (text (texpresso-view--take-out statements)))
    (with-current-buffer buf
      (pcase-let* ((`(,_ ,beg ,end) (texpresso-view--frame))
                   (layer (texpresso-view--layer beg end)))
        (save-excursion
          (if front
              (goto-char (save-excursion (goto-char (cdr layer)) (line-beginning-position)))
            (goto-char (car layer))
            (forward-line 1))
          (insert text))))
    (texpresso-view--select (number-sequence (if front (1+ (- n count)) 1) (if front n count)))
    (texpresso-view--draw-page)))

(defun texpresso-view-bring-to-front ()
  "Put the object selected over all the others on its slide."
  (interactive)
  (texpresso-view--move-to-end t))

(defun texpresso-view-send-to-back ()
  "Put the object selected under all the others on its slide."
  (interactive)
  (texpresso-view--move-to-end nil))

(defun texpresso-view-copy-object ()
  "Copy the objects selected, to paste them on this slide or another."
  (interactive)
  (kill-new (mapconcat (lambda (statement)
                         (let ((r (texpresso-view--statement-region statement)))
                           (with-current-buffer (car statement)
                             (buffer-substring-no-properties (car r) (cdr r)))))
                       (texpresso-view--selected-statements) ""))
  (message "Copied: paste it with a right click"))

(defun texpresso-view--copied-objects ()
  "The objects last copied or cut, their nodes, if that is what was copied last."
  (let ((text (ignore-errors (current-kill 0 t))))
    (when (and (stringp text) (string-match-p "\\`[ \t\n]*\\\\node[ \t\n]*\\[tv[],]" text))
      (with-temp-buffer
        (insert text)
        (let ((statements (texpresso-view--statements (point-min) (point-max))))
          (and statements
               (string-match-p "\\`[ \t\n]*\\'"
                               (buffer-substring (cdr (car (last statements))) (point-max)))
               (mapcar (lambda (s) (buffer-substring-no-properties (car s) (cdr s)))
                       statements)))))))

(defun texpresso-view-paste ()
  "Paste on the slide what was copied: a picture, or an object.
A picture on the clipboard (a screenshot) is saved in the document's
figures/ and put where the slide was last clicked; an object copied or
cut goes where it was, a little lower when that place is taken."
  (interactive)
  (let ((objects (texpresso-view--copied-objects)))
    (cond
     ((and (not objects) (texpresso-view--clipboard-png))
      (texpresso-view-paste-image))
     (objects
      (let* ((places (delq nil (mapcar #'texpresso-view--centre
                                       (texpresso-view--frame-statements))))
             (statements (mapcar #'texpresso-view--insert-object objects))
             (n (length (texpresso-view--frame-statements))))
        (while (seq-some (lambda (s) (member (texpresso-view--centre s) places)) statements)
          (dolist (s statements)
            (texpresso-view--shift s 3 3)))
        (texpresso-view--select (number-sequence (1+ (- n (length statements))) n))
        (texpresso-view--draw-page)))
     (t (user-error "Nothing to paste: no picture on the clipboard, no object copied")))))

(defun texpresso-view-undo ()
  "Undo the last change to the slide on display's source."
  (interactive)
  (let ((frame (texpresso-view--frame)))
    (with-current-buffer (if frame (car frame) (texpresso-view--root-buffer))
      (undo-only))))

(defun texpresso-view-redo ()
  "Redo the last change undone in the slide on display's source."
  (interactive)
  (let ((frame (texpresso-view--frame)))
    (with-current-buffer (if frame (car frame) (texpresso-view--root-buffer))
      (undo-redo))))

;;; The toolbar, the menus and the picture panel: everything above on the
;;; slide reached with the mouse, as in Google Slides.  The toolbar is the
;;; page window's header line on a Beamer deck: icons drawn as SVG, in the
;;; colours of the theme; a right click on the slide opens a menu of what
;;; can be done there; the menu bar has a Slides menu.

(defvar texpresso-view--deck nil
  "Whether the document on display is a Beamer deck: (ROOT . DECK-P).")

(defun texpresso-view--deck-p ()
  "Non-nil if the document on display is a Beamer deck."
  (when texpresso-view--root
    (unless (equal (car texpresso-view--deck) texpresso-view--root)
      (setq texpresso-view--deck
            (cons texpresso-view--root
                  (with-current-buffer (texpresso-view--root-buffer)
                    (save-excursion
                      (save-restriction
                        (widen)
                        (goto-char (point-min))
                        (and (re-search-forward
                              "^[ \t]*\\\\documentclass[ \t]*\\(?:\\[[^]]*\\]\\)?[ \t]*{beamer}" nil t)
                             t)))))))
    (cdr texpresso-view--deck)))

(defconst texpresso-view--icons
  '((undo "M8 5 L4 9 L8 13" "M4 9 H12 C15 9 17 11 17 14 C17 16 15 17 13 17")
    (redo "M12 5 L16 9 L12 13" "M16 9 H8 C5 9 3 11 3 14 C3 16 5 17 7 17")
    (text "M5 5 H15" "M10 5 V16" "M8 16 H12")
    (picture "M3 4 H17 V16 H3 Z" "M4 15 L8 10 L11 13 L13 11 L16 15" "M12.5 7 h1.5 v1.5 h-1.5 Z")
    (duplicate "M7 7 H17 V17 H7 Z" "M4 14 V4 H14")
    (delete "M4 6 H16" "M8 6 V4 H12 V6" "M6 6 L7 17 H13 L14 6" "M9 9 V14" "M11 9 V14")
    (front "M3 3 H11 V11 H3 Z" (fill "M8 8 H17 V17 H8 Z"))
    (back (fill "M3 3 H11 V11 H3 Z") "M8 8 H17 V17 H8 Z")
    (slides "M3 3 H17 V7 H3 Z" "M3 9 H17 V13 H3 Z" "M3 15 H17 V17")
    (shape "M3 9 H11 V17 H3 Z" "M9.5 8 A4.5 4.5 0 1 1 18.5 8 A4.5 4.5 0 1 1 9.5 8 Z")
    (line "M4 16 L16 4")
    (bold "M6 4 H11 C14 4 14 9.5 11 9.5 H6 Z" "M6 9.5 H12 C15.5 9.5 15.5 16 12 16 H6 Z")
    (italic "M9 4 H15" "M5 16 H11" "M12 4 L8 16")
    (align-left "M3 5 H17" "M3 9 H12" "M3 13 H17" "M3 17 H10")
    (align-center "M3 5 H17" "M6 9 H14" "M3 13 H17" "M7 17 H13")
    (align-right "M3 5 H17" "M8 9 H17" "M3 13 H17" "M10 17 H17")
    (rotate-left "M5 8 A6 6 0 1 1 6 14" "M2 5 L5 8 L8 5")
    (rotate-right "M15 8 A6 6 0 1 0 14 14" "M18 5 L15 8 L12 5")
    (weight (fill "M3 4 H17 V5 H3 Z") (fill "M3 8 H17 V10 H3 Z") (fill "M3 13 H17 V16 H3 Z"))
    (dash "M3 5 H17" "M3 10 H6 M9 10 H12 M15 10 H17" "M3 15 H4 M7 15 H8 M11 15 H12 M15 15 H16")
    (new-slide "M3 5 H17 V15 H3 Z" "M10 7.5 V12.5" "M7.5 10 H12.5"))
  "The toolbar's icons, on a 20 x 20 grid: (NAME PATH …).
A path is a string of SVG path data, stroked; (fill PATH) is filled too,
and drawn over what comes before it.")

(defun texpresso-view--icon (name color)
  "The toolbar icon NAME drawn in COLOR, as an image."
  (let* ((size (max 16 (round (* 1.1 (frame-char-height)))))
         (svg (svg-create size size :viewBox "0 0 20 20" :stroke color :stroke-width 1.5
                          :fill "none" :stroke-linecap "round" :stroke-linejoin "round")))
    (dolist (path (cdr (assq name texpresso-view--icons)))
      (if (consp path)
          (svg-node svg 'path :d (cadr path) :fill color)
        (svg-node svg 'path :d path)))
    (svg-image svg :ascent 'center :scale 1.0)))

(defvar texpresso-view--toolbar-cache nil
  "The toolbar last made, and what it was made from: (KEY . STRING).")

(defvar texpresso-view--toolbar-map
  (let ((map (make-sparse-keymap)))
    (define-key map [header-line down-mouse-1] #'ignore)
    (define-key map [header-line mouse-1] #'texpresso-view-toolbar-click)
    (define-key map [tab-line down-mouse-1] #'ignore)
    (define-key map [tab-line mouse-1] #'texpresso-view-toolbar-click)
    map)
  "The keys of a toolbar button, in the tab line or the header line.")

(defun texpresso-view--button (icon label help action &optional off active)
  "A toolbar button: ICON (a name in `texpresso-view--icons', or nil) and LABEL.
ICON may also be an image.  HELP is its tooltip; ACTION the command a
click runs (with the click as its event when it takes one); OFF greys it
out and makes it do nothing; ACTIVE shows it pressed."
  (let* ((color (face-attribute (if off 'shadow 'default) :foreground nil t))
         (color (if (and (stringp color) (not (string-prefix-p "unspecified" color))) color "gray50"))
         (text (concat " "
                       (cond ((null icon) "")
                             ((symbolp icon) (propertize " " 'display (texpresso-view--icon icon color)))
                             (t (propertize " " 'display icon)))
                       (if (and icon label) " " "")
                       (or label "")
                       " ")))
    (if off
        (propertize text 'face 'shadow 'help-echo help)
      (propertize text
                  'face (and active 'texpresso-view-button-on)
                  'mouse-face 'highlight
                  'help-echo help
                  'pointer 'hand
                  'texpresso-view-action action
                  'local-map texpresso-view--toolbar-map))))

(defun texpresso-view-toolbar-click (event)
  "Run the action of the toolbar button clicked in EVENT."
  (interactive "e")
  (let* ((posn (event-start event))
         (string (posn-string posn))
         (action (and string (get-text-property (cdr string) 'texpresso-view-action
                                                (car string)))))
    (when action
      (if (and (commandp action)
               (let ((spec (cadr (interactive-form action))))
                 (and (stringp spec) (string-prefix-p "e" spec))))
          (funcall action event)
        (call-interactively action)))))

(defun texpresso-view--toolbar ()
  "The slide toolbar, for the page window's header line, on a Beamer deck."
  (when (and (texpresso-view--deck-p) texpresso-view--png
             (not (texpresso-view--tty-p (texpresso-view--window))))
    (let ((key (list (null texpresso-view--selected)
                     (face-attribute 'default :foreground nil t)
                     (frame-char-height))))
      (if (equal key (car texpresso-view--toolbar-cache))
          (cdr texpresso-view--toolbar-cache)
        (let* ((off (null texpresso-view--selected))
               (bar (concat
                     (texpresso-view--button 'undo nil "Undo" #'texpresso-view-undo)
                     (texpresso-view--button 'redo nil "Redo" #'texpresso-view-redo)
                     (propertize " │" 'face 'shadow)
                     (texpresso-view--button 'text "Text" "Add a text box where you last clicked"
                                             #'texpresso-view-add-text)
                     (texpresso-view--button 'picture "Picture ▾" "Insert a picture"
                                             #'texpresso-view-picture-menu)
                     (texpresso-view--button 'shape "Shape ▾" "Insert a shape"
                                             #'texpresso-view-shape-menu)
                     (texpresso-view--button 'line "Line ▾" "Insert a line or an arrow"
                                             #'texpresso-view-line-menu)
                     (propertize " │" 'face 'shadow)
                     (texpresso-view--button 'duplicate nil "Duplicate the object selected"
                                             #'texpresso-view-duplicate-object off)
                     (texpresso-view--button 'delete nil "Delete the object selected"
                                             #'texpresso-view-delete-object off)
                     (texpresso-view--button 'front nil "Bring to front"
                                             #'texpresso-view-bring-to-front off)
                     (texpresso-view--button 'back nil "Send to back"
                                             #'texpresso-view-send-to-back off)
                     (propertize " │" 'face 'shadow)
                     (texpresso-view--button 'slides "Slides" "Show or hide the slide strip"
                                             #'texpresso-view-slides)
                     (texpresso-view--button 'new-slide "▾" "Add, duplicate or delete a slide"
                                             #'texpresso-view-slide-menu))))
          (setq texpresso-view--toolbar-cache (cons key bar))
          bar)))))

(defvar texpresso-view-layouts)
(defvar texpresso-view-slides-buffer-name)
(defvar texpresso-view--strip-frames)

(defun texpresso-view--layout-items (command)
  "Menu items running COMMAND with each of `texpresso-view-layouts'."
  (mapcar (lambda (layout)
            (vector (car layout)
                    (lambda () (interactive) (funcall command (car layout)))
                    t))
          texpresso-view-layouts))

(defun texpresso-view--picture-items ()
  "The menu items that put a picture on the slide."
  '(["From your computer…" texpresso-view-insert-image t]
    ["Recent pictures…" texpresso-view-pictures t]
    ["Paste from the clipboard" texpresso-view-paste-image t]))

(defun texpresso-view--slide-items ()
  "The menu items about the slide on display."
  `(("New slide after this one" ,@(texpresso-view--layout-items #'texpresso-view-new-slide))
    ["Duplicate this slide" texpresso-view-duplicate-slide t]
    ["Delete this slide" texpresso-view-delete-slide t]
    ["Show or hide the slide strip" texpresso-view-slides t]
    "---"
    ,@(texpresso-view--deck-items)))

(defun texpresso-view--object-items ()
  "The menu items about the object selected."
  (let ((on texpresso-view--selected))
    `(["Cut" texpresso-view-cut-object ,on]
      ["Copy" texpresso-view-copy-object ,on]
      ["Paste" texpresso-view-paste t]
      ["Duplicate" texpresso-view-duplicate-object ,on]
      ["Delete" texpresso-view-delete-object ,on]
      "---"
      ("Order"
       ["Bring to front" texpresso-view-bring-to-front ,on]
       ["Bring forward" texpresso-view-raise-object ,on]
       ["Send backward" texpresso-view-lower-object ,on]
       ["Send to back" texpresso-view-send-to-back ,on])
      ("Size"
       ["Larger" texpresso-view-larger ,on]
       ["Smaller" texpresso-view-smaller ,on])
      ("Arrange" ,@(texpresso-view--arrange-items))
      ("Rotate"
       ["A quarter to the left" texpresso-view-rotate-left ,on]
       ["A quarter to the right" texpresso-view-rotate-right ,on]
       ["Upright" (lambda () (interactive) (texpresso-view-rotate-by
                                            (- (texpresso-view--angle
                                                (texpresso-view--selected-statement)))))
        ,on])
      "---"
      ["Edit text" texpresso-view-edit-text ,on]
      ["Crop" texpresso-view-crop ,on]
      ["Show all of the picture" texpresso-view-uncrop ,on]
      ["Edit in the source" texpresso-view-edit-object ,on])))

(defun texpresso-view-picture-menu (event)
  "The toolbar's picture menu, at the click EVENT."
  (interactive "e")
  (popup-menu (easy-menu-create-menu "Picture" (texpresso-view--picture-items)) event))

(defun texpresso-view-slide-menu (event)
  "The toolbar's slide menu, at the click EVENT."
  (interactive "e")
  (popup-menu (easy-menu-create-menu "Slide" (texpresso-view--slide-items)) event))

(defun texpresso-view-context-menu (event)
  "The menu of what can be done where the slide was right-clicked, EVENT.
On an object, it is selected and the menu is about it; elsewhere, the
spot is where a new object goes, and the menu inserts one."
  (interactive "e")
  (let* ((at (texpresso-view--event-units event))
         (hit (and at (texpresso-view--hit (car at) (cdr at)))))
    (select-window (posn-window (event-start event)))
    (cond
     ((and hit (memq (car hit) (texpresso-view--selection))))
     (hit (texpresso-view--select (texpresso-view--group-of (car hit))))
     (t (texpresso-view--select nil)
        (setq texpresso-view--anchor (or at texpresso-view--anchor))))
    (texpresso-view--draw-page)
    (popup-menu
     (easy-menu-create-menu
      "Slide"
      (if hit
          (texpresso-view--object-items)
        `(["Paste" texpresso-view-paste t]
          ["Text box" texpresso-view-add-text t]
          ("Picture" ,@(texpresso-view--picture-items))
          ("Shape" ,@(texpresso-view--shape-items))
          ("Line" ,@(texpresso-view--line-items))
          ("Table" ,@(texpresso-view--table-items))
          "---"
          ,@(texpresso-view--slide-items))))
     event)))

;;; A picture panel, as Google Slides' "Insert image": the pictures of the
;;; document's folder and of the user's picture folders, newest first, as
;;; small previews made once by ImageMagick (pdftoppm for a PDF) and kept
;;; in the cache; a click puts one on the slide.

(defcustom texpresso-view-picture-folders
  '("~/Pictures" "~/Pictures/Screenshots" "~/Downloads" "~/Desktop")
  "Folders whose pictures the picture panel offers, after the document's own."
  :type '(repeat directory)
  :group 'tex)

(defconst texpresso-view-pictures-buffer-name "*Slide pictures*"
  "The buffer of the picture panel.")

(defconst texpresso-view--pictures-max 40
  "How many pictures the panel offers at most.")

(defun texpresso-view--recent-pictures ()
  "The pictures to offer, newest first: the document's, then the user's."
  (let* ((dir (file-name-directory texpresso-view--root))
         (folders (delete-dups (mapcar #'expand-file-name
                                       (append (list dir (expand-file-name "figures" dir))
                                               texpresso-view-picture-folders))))
         (case-fold-search t)
         files)
    (dolist (folder folders)
      (when (file-directory-p folder)
        (dolist (file (directory-files folder t texpresso-view--image-regexp t))
          (when (file-regular-p file)
            (push (cons file (file-attribute-modification-time (file-attributes file))) files)))))
    (mapcar #'car
            (seq-take (sort (delete-dups files) (lambda (a b) (time-less-p (cdr b) (cdr a))))
                      texpresso-view--pictures-max))))

(defun texpresso-view--thumbnail (file)
  "A small PNG preview of the picture FILE, made once: its path, or nil."
  (let* ((dir (expand-file-name "texpresso-view/previews"
                                (or (getenv "XDG_CACHE_HOME") "~/.cache")))
         (thumb (expand-file-name
                 (concat (md5 (format "%s %s" file (file-attribute-modification-time
                                                    (file-attributes file))))
                         ".png")
                 dir)))
    (unless (file-exists-p thumb)
      (make-directory dir t)
      (if (string-match-p "\\.pdf\\'" (downcase file))
          (call-process "pdftoppm" nil nil nil "-png" "-singlefile" "-f" "1" "-l" "1"
                        "-scale-to" "200" file (file-name-sans-extension thumb))
        (call-process "magick" nil nil nil (concat file "[0]") "-thumbnail" "200x130" thumb)))
    (and (file-exists-p thumb) thumb)))

(defvar texpresso-view-pictures-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'texpresso-view-pictures-click)
    (define-key map (kbd "RET") #'texpresso-view-pictures-click)
    (define-key map (kbd "q") #'texpresso-view-pictures-close)
    map)
  "Keys of the picture panel.")

(define-derived-mode texpresso-view-pictures-mode special-mode "Pictures"
  "Pictures to put on the slide: a click puts one there.
\\{texpresso-view-pictures-mode-map}"
  (setq-local cursor-type nil)
  (setq-local display-line-numbers nil))

(defvar texpresso-view--pictures-timer nil
  "The timer adding the panel's next preview.")

(defun texpresso-view-pictures ()
  "Show the pictures to put on the slide, newest first: a click puts one there.
They are the document's folder's, its figures/'s, and those of
`texpresso-view-picture-folders'."
  (interactive)
  (unless texpresso-view--root
    (user-error "No TeXpresso view open"))
  (let ((buf (get-buffer-create texpresso-view-pictures-buffer-name))
        (files (texpresso-view--recent-pictures)))
    (with-current-buffer buf
      (texpresso-view-pictures-mode)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize "Click a picture to put it on the slide" 'face 'bold) "   ")
        (insert-text-button "From your computer…"
                            'action (lambda (_) (call-interactively #'texpresso-view-insert-image)))
        (insert "   ")
        (insert-text-button "Close" 'action (lambda (_) (texpresso-view-pictures-close)))
        (insert "\n\n")
        (unless files
          (insert "No pictures in the document's folder or in "
                  (string-join texpresso-view-picture-folders ", ") "\n"))))
    (display-buffer-in-side-window buf '((side . bottom) (slot . 0) (window-height . 0.3)))
    (when (timerp texpresso-view--pictures-timer)
      (cancel-timer texpresso-view--pictures-timer))
    ;; the previews come one at a time, the first ones made at once
    (cl-labels ((next (files)
                  (when (and files (buffer-live-p buf))
                    (let ((thumb (texpresso-view--thumbnail (car files))))
                      (when thumb
                        (with-current-buffer buf
                          (let ((inhibit-read-only t))
                            (save-excursion
                              (goto-char (point-max))
                              (insert (propertize
                                       " " 'display (create-image thumb 'png nil :max-height 110
                                                                  :margin 4)
                                       'texpresso-view-picture (car files)
                                       'mouse-face 'highlight
                                       'pointer 'hand
                                       'help-echo (abbreviate-file-name (car files)))))))))
                    (setq texpresso-view--pictures-timer
                          (run-with-timer 0.01 nil #'next (cdr files))))))
      (next files))))

(defun texpresso-view-pictures-close ()
  "Close the picture panel."
  (interactive)
  (let ((buf (get-buffer texpresso-view-pictures-buffer-name)))
    (when buf
      (let ((win (get-buffer-window buf t)))
        (when win (delete-window win)))
      (kill-buffer buf))))

(defun texpresso-view-pictures-click (&optional event)
  "Put the picture clicked in EVENT, or at point, on the slide."
  (interactive (list last-nonmenu-event))
  (let* ((mouse (mouse-event-p event))
         (pos (if mouse (posn-point (event-start event)) (point)))
         (file (and pos (get-text-property pos 'texpresso-view-picture
                                           (if mouse (window-buffer (posn-window (event-start event)))
                                             (current-buffer))))))
    (when file
      (texpresso-view-pictures-close)
      (let ((page (texpresso-view--window)))
        (when page (select-window page)))
      (texpresso-view--insert-image file))))

;;; The slide on display, from the toolbar and the menus: what the strip
;;; does to the slide at its point, done to this one.

(defun texpresso-view--on-slide (command &rest args)
  "Run the strip's COMMAND with ARGS on the slide on display.
The strip opens if it is closed, to show what changes."
  (unless (texpresso-view--strip-window)
    (texpresso-view-slides))
  (let* ((start (texpresso-view--frame-marker))
         (i (and start (seq-position texpresso-view--strip-frames start
                                     (lambda (f m) (and (eq (nth 0 f) (marker-buffer m))
                                                        (= (nth 1 f) m)))))))
    (unless i
      (user-error "This slide has no \\begin{frame} of its own in the deck (a macro makes it?)"))
    (with-current-buffer texpresso-view-slides-buffer-name
      (texpresso-view--strip-goto i)
      (apply command args))))

(defun texpresso-view-new-slide (layout)
  "Add a slide from LAYOUT after the one on display."
  (interactive (list (completing-read "Layout: " texpresso-view-layouts nil t nil nil
                                      (caar texpresso-view-layouts))))
  (texpresso-view--on-slide #'texpresso-view-slides-new layout))

(defun texpresso-view-duplicate-slide ()
  "Put a copy of the slide on display after it."
  (interactive)
  (texpresso-view--on-slide #'texpresso-view-slides-duplicate))

(defun texpresso-view-delete-slide ()
  "Delete the slide on display, onto the kill ring."
  (interactive)
  (texpresso-view--on-slide #'texpresso-view-slides-delete))

;;; The objects' look, written as TikZ keys in the node's [ ]: its fill,
;;; its border (draw), the border's weight and dashes, the text's colour,
;;; size, bold, italic and alignment, its opacity and angle; a line's
;;; colour, weight, dashes and arrow heads in its `tv line={…}'.  The
;;; format bar over the page, the header line under the toolbar, shows
;;; them for the object selected and changes them; a colour is picked from
;;; a palette that takes the bar's place, as xcolor expressions (red!40).

(defun texpresso-view--options-region (statement)
  "Where STATEMENT's node options are: (BEG . END) inside its [ ], or nil."
  (pcase-let ((`(,buf ,beg ,end) statement))
    (with-current-buffer buf
      (save-excursion
        (goto-char beg)
        (when (re-search-forward "\\\\node[ \t\n]*\\[" end t)
          (let ((close (texpresso-view--group-end (1- (point)) ?\[ ?\])))
            (and close (<= close end) (cons (point) (1- close)))))))))

(defun texpresso-view--split-options (text)
  "TEXT, a TikZ option list, as its items: trimmed strings, empty ones left out."
  (let ((depth 0) (start 0) items)
    (dotimes (i (length text))
      (let ((c (aref text i)))
        (cond ((memq c '(?\{ ?\[)) (setq depth (1+ depth)))
              ((memq c '(?\} ?\])) (setq depth (1- depth)))
              ((and (eq c ?,) (= depth 0))
               (push (string-trim (substring text start i)) items)
               (setq start (1+ i))))))
    (push (string-trim (substring text start)) items)
    (seq-remove #'string-empty-p (nreverse items))))

(defun texpresso-view--item-key (item)
  "The key of the option ITEM: what comes before its =, or all of it."
  (string-trim (if (string-match "=" item) (substring item 0 (match-beginning 0)) item)))

(defun texpresso-view--item-value (item)
  "The value of the option ITEM, after its =, or t for a key alone."
  (if (string-match "=" item) (string-trim (substring item (match-end 0))) t))

(defun texpresso-view--unbrace (value)
  "VALUE without the braces around all of it, if it has them."
  (if (and (> (length value) 1) (eq (aref value 0) ?\{)
           (let ((depth 0) (i 0) (whole t))
             (while (and whole (< i (length value)))
               (pcase (aref value i)
                 (?\{ (setq depth (1+ depth)))
                 (?\} (setq depth (1- depth))
                      (when (and (= depth 0) (< i (1- (length value))))
                        (setq whole nil))))
               (setq i (1+ i)))
             whole))
      (substring value 1 -1)
    value))

(defun texpresso-view--items (statement &optional line)
  "STATEMENT's node options as items; with LINE, its tv line's."
  (let* ((region (texpresso-view--options-region statement))
         (items (and region
                     (with-current-buffer (car statement)
                       (texpresso-view--split-options
                        (buffer-substring-no-properties (car region) (cdr region)))))))
    (if line
        (let ((item (seq-find (lambda (i) (equal (texpresso-view--item-key i) "tv line")) items)))
          (and item (stringp (texpresso-view--item-value item))
               (texpresso-view--split-options
                (texpresso-view--unbrace (texpresso-view--item-value item)))))
      items)))

(defun texpresso-view--option (statement key &optional line)
  "The value STATEMENT gives KEY: a string, t for the key alone, or nil.
With LINE, among the options of its tv line."
  (let ((item (seq-find (lambda (i) (equal (texpresso-view--item-key i) key))
                        (texpresso-view--items statement line))))
    (and item (texpresso-view--item-value item))))

(defun texpresso-view--edit-items (statement fn &optional line)
  "Rewrite STATEMENT's node options as FN makes them from the items it has.
With LINE, the options of its tv line."
  (let ((region (texpresso-view--options-region statement)))
    (when region
      (with-current-buffer (car statement)
        (let* ((old (buffer-substring-no-properties (car region) (cdr region)))
               (items (texpresso-view--split-options old))
               (new (if line
                        (mapcar (lambda (i)
                                  (if (not (equal (texpresso-view--item-key i) "tv line"))
                                      i
                                    (let ((v (texpresso-view--item-value i)))
                                      (format "tv line={%s}"
                                              (string-join
                                               (funcall fn (texpresso-view--split-options
                                                            (if (stringp v) (texpresso-view--unbrace v) "")))
                                               ",")))))
                                items)
                      (funcall fn items)))
               (text (string-join new ",")))
          (unless (equal text old)
            (save-excursion
              (goto-char (car region))
              (delete-region (car region) (cdr region))
              (insert text))))))))

(defun texpresso-view--put-option (statement key value &optional line)
  "Give KEY the VALUE in STATEMENT's options; with LINE, its tv line's.
VALUE is a string, t for the key alone, or nil to take the key away."
  (texpresso-view--edit-items
   statement
   (lambda (items)
     (let* ((item (cond ((null value) nil) ((eq value t) key) (t (format "%s=%s" key value))))
            (found nil)
            (new (delq nil (mapcar (lambda (i)
                                     (if (equal (texpresso-view--item-key i) key)
                                         (unless found (setq found t) item)
                                       i))
                                   items))))
       (if (or found (null item)) new (append new (list item)))))
   line))

(defun texpresso-view--angle (statement)
  "STATEMENT's angle, in degrees counter-clockwise, or 0."
  (let ((v (texpresso-view--option statement "rotate")))
    (or (and (stringp v) (string-match-p "\\`-?[0-9.]+\\'" v) (string-to-number v)) 0)))

(defconst texpresso-view--dashes
  '("solid" "dashed" "dotted" "densely dashed" "densely dotted" "loosely dashed"
    "loosely dotted" "dash dot")
  "TikZ's dash keys: one at most in an object's options.")

(defun texpresso-view--arrow-item-p (item)
  "Non-nil if the option ITEM gives a line's arrow heads, as -{Stealth}."
  (string-match-p "\\`\\(?:{[^}]*}\\|[<>|]*\\)-\\(?:{[^}]*}\\|[<>|]*\\)\\'" item))

(defun texpresso-view--font (statement)
  "STATEMENT's text style: (SIZE BOLD ITALIC), SIZE in points or nil."
  (let ((v (texpresso-view--option statement "font")))
    (if (stringp v)
        (list (and (string-match "\\\\fontsize{\\([0-9.]+\\)}" v)
                   (string-to-number (match-string 1 v)))
              (and (string-match-p "\\\\bfseries" v) t)
              (and (string-match-p "\\\\itshape" v) t))
      (list nil nil nil))))

(defun texpresso-view--set-font (statement size bold italic)
  "Give STATEMENT's text the SIZE in points (nil: the slide's), BOLD and ITALIC."
  (let ((v (concat (if size
                       (format "\\fontsize{%s}{%s}\\selectfont" (texpresso-view--number size)
                               (texpresso-view--number (* 1.2 size)))
                     "")
                   (if bold "\\bfseries" "")
                   (if italic "\\itshape" ""))))
    (texpresso-view--put-option statement "font" (and (not (string-empty-p v)) (concat "{" v "}")))))

(defun texpresso-view--format (fn)
  "Call FN with each object selected's node and kind, then draw the page again."
  (dolist (statement (texpresso-view--selected-statements))
    (funcall fn statement (texpresso-view--kind statement)))
  (setq texpresso-view--format-cache nil)
  (texpresso-view--draw-page))

(defun texpresso-view-set-color (target color)
  "Give the object selected's TARGET the COLOR, an xcolor expression; nil: none.
TARGET is `fill', `border', `text', or `line' for a line's colour."
  (texpresso-view--format
   (lambda (statement _kind)
     (pcase target
       ('fill (texpresso-view--put-option statement "fill" color))
       ('text (texpresso-view--put-option statement "text" color))
       ('line (texpresso-view--put-option statement "color" (or color "black") t))
       ('border
        (texpresso-view--put-option statement "draw" color)
        (if color
            (unless (texpresso-view--option statement "line width")
              (texpresso-view--put-option statement "line width" "1pt"))
          (texpresso-view--put-option statement "line width" nil)))))))

(defun texpresso-view-set-weight (points)
  "Make the object selected's border, or its line, POINTS thick; 0: no border."
  (texpresso-view--format
   (lambda (statement kind)
     (cond
      ((eq kind 'line)
       (texpresso-view--put-option statement "line width"
                                   (format "%spt" (texpresso-view--number (max 0.5 points))) t))
      ((zerop points)
       (texpresso-view--put-option statement "draw" nil)
       (texpresso-view--put-option statement "line width" nil))
      (t
       (texpresso-view--put-option statement "line width"
                                   (format "%spt" (texpresso-view--number points)))
       (unless (texpresso-view--option statement "draw")
         (texpresso-view--put-option statement "draw" "black")))))))

(defun texpresso-view-set-dash (style)
  "Draw the object selected's border, or its line, in STYLE.
STYLE is one of `texpresso-view--dashes': solid, dashed, dotted…"
  (texpresso-view--format
   (lambda (statement kind)
     (texpresso-view--edit-items
      statement
      (lambda (items)
        (append (seq-remove (lambda (i) (member i texpresso-view--dashes)) items)
                (unless (equal style "solid") (list style))))
      (eq kind 'line))
     (unless (or (eq kind 'line) (texpresso-view--option statement "draw"))
       (texpresso-view--put-option statement "draw" "black")))))

(defun texpresso-view-set-arrows (spec)
  "Give the line selected the arrow heads SPEC, as -{Stealth}; - for none."
  (texpresso-view--format
   (lambda (statement _kind)
     (texpresso-view--edit-items
      statement
      (lambda (items) (cons spec (seq-remove #'texpresso-view--arrow-item-p items)))
      t))))

(defun texpresso-view-set-size (points)
  "Make the text of the object selected POINTS large; nil: the slide's size."
  (texpresso-view--format
   (lambda (statement _kind)
     (pcase-let ((`(,_ ,bold ,italic) (texpresso-view--font statement)))
       (texpresso-view--set-font statement points bold italic)))))

(defun texpresso-view-toggle-bold ()
  "Make the text of the object selected bold, or bold no more."
  (interactive)
  (texpresso-view--format
   (lambda (statement _kind)
     (pcase-let ((`(,size ,bold ,italic) (texpresso-view--font statement)))
       (texpresso-view--set-font statement size (not bold) italic)))))

(defun texpresso-view-toggle-italic ()
  "Make the text of the object selected italic, or italic no more."
  (interactive)
  (texpresso-view--format
   (lambda (statement _kind)
     (pcase-let ((`(,size ,bold ,italic) (texpresso-view--font statement)))
       (texpresso-view--set-font statement size bold (not italic))))))

(defun texpresso-view-set-align (where)
  "Align the text of the object selected WHERE: left, center or right."
  (texpresso-view--format
   (lambda (statement _kind)
     (texpresso-view--put-option statement "align" where))))

(defun texpresso-view-set-opacity (opacity)
  "Make the object selected OPACITY opaque, from 0 to 1."
  (texpresso-view--format
   (lambda (statement _kind)
     (texpresso-view--put-option statement "opacity"
                                 (and (< opacity 1) (format "%s" opacity))))))

(defun texpresso-view-rotate-by (degrees)
  "Turn the object selected by DEGREES, counter-clockwise, about its centre."
  (texpresso-view--format
   (lambda (statement _kind)
     (let ((a (mod (+ (texpresso-view--angle statement) degrees) 360)))
       (when (> a 180) (setq a (- a 360)))
       (texpresso-view--put-option statement "rotate"
                                   (and (/= a 0) (texpresso-view--number a)))))))

(defun texpresso-view-rotate-left ()
  "Turn the object selected a quarter turn to the left."
  (interactive)
  (texpresso-view-rotate-by 90))

(defun texpresso-view-rotate-right ()
  "Turn the object selected a quarter turn to the right."
  (interactive)
  (texpresso-view-rotate-by -90))

;;; Colours: a palette of xcolor expressions, and their RGB to draw them.

(defconst texpresso-view--base-colors
  '(("red" 1 0 0) ("green" 0 1 0) ("blue" 0 0 1) ("cyan" 0 1 1) ("magenta" 1 0 1)
    ("yellow" 1 1 0) ("black" 0 0 0) ("white" 1 1 1) ("gray" 0.5 0.5 0.5)
    ("darkgray" 0.25 0.25 0.25) ("lightgray" 0.75 0.75 0.75) ("brown" 0.75 0.5 0.25)
    ("lime" 0.75 1 0) ("olive" 0.5 0.5 0) ("orange" 1 0.5 0) ("pink" 1 0.75 0.75)
    ("purple" 0.75 0 0.25) ("teal" 0 0.5 0.5) ("violet" 0.5 0 0.5))
  "The base colours of xcolor, with their RGB.")

(defconst texpresso-view--hues
  '("red" "orange" "yellow" "green!70!black" "cyan!80!black" "blue" "violet" "magenta")
  "The palette's hues, each in four shades.")

(defun texpresso-view--palette-colors ()
  "The colours the palette offers, as xcolor expressions."
  (append '("black" "black!70" "black!45" "black!20" "white")
          (apply #'append
                 (mapcar (lambda (h) (list (concat h "!60!black") h (concat h "!40") (concat h "!15")))
                         texpresso-view--hues))))

(defun texpresso-view--color-hex (expr)
  "The colour of the xcolor expression EXPR as #RRGGBB, or nil if unknown.
EXPR is a base colour, mixed in turn with others: red!40, blue!60!black."
  (let* ((parts (split-string expr "!"))
         (rgb (cdr (assoc (car parts) texpresso-view--base-colors))))
    (setq parts (cdr parts))
    (while (and rgb parts)
      (let ((share (/ (string-to-number (car parts)) 100.0))
            (other (if (cdr parts) (cdr (assoc (cadr parts) texpresso-view--base-colors)) '(1 1 1))))
        (setq rgb (and other (seq-mapn (lambda (a b) (+ (* share a) (* (- 1 share) b))) rgb other))
              parts (cddr parts))))
    (and rgb (apply #'format "#%02x%02x%02x" (mapcar (lambda (v) (round (* 255 v))) rgb)))))

(defun texpresso-view--chip (color)
  "A small square of COLOR, an xcolor expression (nil: none), as an image."
  (let* ((size (max 14 (round (* 0.9 (frame-char-height)))))
         (svg (svg-create size size))
         (hex (and color (texpresso-view--color-hex color))))
    (svg-rectangle svg 1 1 (- size 2) (- size 2) :fill (or hex "white")
                   :stroke "gray50" :stroke-width 1)
    (unless color
      (svg-line svg 2 (- size 2) (- size 2) 2 :stroke "red" :stroke-width 1.5))
    (svg-image svg :ascent 'center :scale 1.0 :margin 1)))

;;; The format bar.

(defface texpresso-view-button-on
  '((t :inherit region))
  "A toolbar button that is on: bold for bold text, the text's alignment."
  :group 'tex)

(defun texpresso-view--choose (event title choices fn)
  "Pop up the menu TITLE at EVENT of CHOICES, ((LABEL . VALUE) …).
FN gets the value picked."
  (let ((value (x-popup-menu event (list title (cons title choices)))))
    (when value
      (funcall fn value))))

(defun texpresso-view-weight-menu (event)
  "The format bar's border or line weight menu, at the click EVENT."
  (interactive "e")
  (texpresso-view--choose event "Weight"
                          '(("None" . 0) ("0.5 pt" . 0.5) ("1 pt" . 1) ("1.5 pt" . 1.5) ("2 pt" . 2)
                            ("3 pt" . 3) ("4 pt" . 4) ("6 pt" . 6))
                          #'texpresso-view-set-weight))

(defun texpresso-view-dash-menu (event)
  "The format bar's dash menu, at the click EVENT."
  (interactive "e")
  (texpresso-view--choose event "Dashes"
                          '(("Solid" . "solid") ("Dashed" . "dashed") ("Dotted" . "dotted")
                            ("Dense dashes" . "densely dashed") ("Dash and dot" . "dash dot"))
                          #'texpresso-view-set-dash))

(defun texpresso-view-arrows-menu (event)
  "The format bar's arrow heads menu, at the click EVENT."
  (interactive "e")
  (texpresso-view--choose event "Arrow heads"
                          '(("None" . "-") ("At the end" . "-{Stealth}") ("At the start" . "{Stealth}-")
                            ("At both ends" . "{Stealth}-{Stealth}"))
                          #'texpresso-view-set-arrows))

(defun texpresso-view-size-menu (event)
  "The format bar's text size menu, at the click EVENT."
  (interactive "e")
  (texpresso-view--choose event "Text size"
                          (cons '("The slide's" . none)
                                (mapcar (lambda (n) (cons (format "%d pt" n) n))
                                        '(8 9 10 11 12 14 16 18 20 24 28 32 36 44)))
                          (lambda (v) (texpresso-view-set-size (and (numberp v) v)))))

(defun texpresso-view-opacity-menu (event)
  "The format bar's opacity menu, at the click EVENT."
  (interactive "e")
  (texpresso-view--choose event "Opacity"
                          '(("100%" . 1) ("75%" . 0.75) ("50%" . 0.5) ("25%" . 0.25))
                          #'texpresso-view-set-opacity))

(defun texpresso-view--palette-action (color)
  "What a click on COLOR in the palette does."
  (lambda ()
    (interactive)
    (let ((target texpresso-view--palette))
      (setq texpresso-view--palette nil)
      (texpresso-view-set-color target color))))

(defun texpresso-view-palette-cancel ()
  "Close the palette, the colour as it was."
  (interactive)
  (setq texpresso-view--palette nil
        texpresso-view--format-cache nil)
  (force-mode-line-update t))

(defun texpresso-view--open-palette (target)
  "What a click on a colour button for TARGET does: the palette for it."
  (lambda ()
    (interactive)
    (setq texpresso-view--palette target
          texpresso-view--format-cache nil)
    (force-mode-line-update t)))

(defun texpresso-view--swatch (color)
  "A colour of the palette: its chip, a click picking COLOR."
  (propertize " " 'display (texpresso-view--chip color)
              'mouse-face 'highlight
              'help-echo (or color "None")
              'pointer 'hand
              'texpresso-view-action (texpresso-view--palette-action color)
              'local-map texpresso-view--toolbar-map))

(defun texpresso-view--palette-bar ()
  "The palette, in the format bar's place."
  (concat (propertize (format " %s: " (pcase texpresso-view--palette
                                        ('fill "Fill") ('border "Border") ('text "Text colour")
                                        (_ "Line colour")))
                      'face 'bold)
          (unless (memq texpresso-view--palette '(text line))
            (texpresso-view--swatch nil))
          (mapconcat #'texpresso-view--swatch (texpresso-view--palette-colors) "")
          " "
          (texpresso-view--button nil "Cancel" "Keep the colour as it is"
                                  #'texpresso-view-palette-cancel)))

(defun texpresso-view--color-button (target label color)
  "The format bar's button for TARGET's colour: LABEL and COLOR's chip."
  (texpresso-view--button (texpresso-view--chip (and (stringp color) color))
                          (concat label " ▾") (format "%s colour" label)
                          (texpresso-view--open-palette target)))

(defun texpresso-view--format-buttons (statement kind)
  "The format bar's buttons for STATEMENT, an object of KIND."
  (let* ((sep (propertize " │" 'face 'shadow))
         (font (texpresso-view--font statement))
         (align (texpresso-view--option statement "align"))
         (fill (texpresso-view--option statement "fill"))
         (draw (texpresso-view--option statement "draw")))
    (concat
     (if (eq kind 'line)
         (concat (texpresso-view--color-button
                  'line "Colour" (or (texpresso-view--option statement "color" t) "black"))
                 (texpresso-view--button 'weight "▾" "Line weight" #'texpresso-view-weight-menu)
                 (texpresso-view--button 'dash "▾" "Solid, dashed or dotted"
                                         #'texpresso-view-dash-menu)
                 (texpresso-view--button nil "Arrows ▾" "Arrow heads" #'texpresso-view-arrows-menu))
       (concat (when (eq kind 'picture)
                 (texpresso-view--button nil "Crop" "Crop the picture with its handles"
                                         #'texpresso-view-crop nil
                                         (eql texpresso-view--cropping texpresso-view--selected)))
               (unless (eq kind 'picture)
                 (texpresso-view--color-button 'fill "Fill" fill))
               (texpresso-view--color-button 'border "Border" (and draw (if (stringp draw) draw "black")))
               (texpresso-view--button 'weight "▾" "Border weight" #'texpresso-view-weight-menu)
               (texpresso-view--button 'dash "▾" "Solid, dashed or dotted border"
                                       #'texpresso-view-dash-menu)))
     (when (memq kind '(text shape))
       (concat sep
               (texpresso-view--color-button 'text "Text" (or (texpresso-view--option statement "text")
                                                             "black"))
               (texpresso-view--button nil (if (car font)
                                               (format "%s pt ▾" (texpresso-view--number (car font)))
                                             "Size ▾")
                                       "Text size" #'texpresso-view-size-menu)
               (texpresso-view--button 'bold nil "Bold" #'texpresso-view-toggle-bold nil (nth 1 font))
               (texpresso-view--button 'italic nil "Italic" #'texpresso-view-toggle-italic nil
                                       (nth 2 font))
               (texpresso-view--button (pcase align ("center" 'align-center) ("right" 'align-right)
                                         (_ 'align-left))
                                       "▾" "Text alignment" #'texpresso-view-align-text-menu)))
     sep
     (texpresso-view--button nil "Arrange ▾" "Align, centre, spread, group, turn, opacity"
                             #'texpresso-view-arrange-menu))))

(defun texpresso-view-align-text-menu (event)
  "The format bar's text alignment menu, at the click EVENT."
  (interactive "e")
  (texpresso-view--choose event "Text alignment"
                          '(("Left" . "left") ("Centre" . "center") ("Right" . "right"))
                          #'texpresso-view-set-align))

(defun texpresso-view--format-bar ()
  "The format bar, for the page window's header line, on a Beamer deck.
It formats the object selected; while a colour is being picked, it is
the palette."
  (cond
   (texpresso-view--palette (texpresso-view--palette-bar))
   ((not texpresso-view--selected)
    (propertize "  Click an object to format it, right-click for more" 'face 'shadow))
   (t
    (let ((statement (nth (1- texpresso-view--selected) (texpresso-view--frame-statements))))
      (when statement
        (let ((key (list (texpresso-view--selection) texpresso-view--cropping
                         (with-current-buffer (car statement)
                           (buffer-substring-no-properties (nth 1 statement) (nth 2 statement)))
                         (face-attribute 'default :foreground nil t)
                         (frame-char-height))))
          (if (equal key (car texpresso-view--format-cache))
              (cdr texpresso-view--format-cache)
            (let ((bar (concat (let ((n (length (texpresso-view--selection))))
                                 (and (> n 1) (propertize (format " %d objects │" n) 'face 'bold)))
                               (texpresso-view--format-buttons statement
                                                               (texpresso-view--kind statement)))))
              (setq texpresso-view--format-cache (cons key bar))
              bar))))))))

;;; Shapes and lines.

(defconst texpresso-view-shapes
  '(("Rectangle" . "rectangle") ("Rounded rectangle" . "rounded") ("Ellipse" . "ellipse")
    ("Diamond" . "diamond") ("Triangle" . "triangle"))
  "The shapes the toolbar offers: (NAME . TV-SHAPE).")

(defconst texpresso-view-line-kinds
  '(("Line" . "-") ("Arrow" . "-{Stealth}") ("Double arrow" . "{Stealth}-{Stealth}"))
  "The lines the toolbar offers: (NAME . ARROW-HEADS).")

(defun texpresso-view-insert-shape (shape)
  "Put the SHAPE, a `tv shape' name, on the slide where it was last pressed."
  (interactive (list (cdr (assoc (completing-read "Shape: " texpresso-view-shapes nil t)
                                 texpresso-view-shapes))))
  (let ((place (texpresso-view--place)))
    (texpresso-view--insert-object
     (format "\\node[tv,tv shape=%s,minimum width=24\\tvu,minimum height=14\\tvu,text width=%s\\tvu,align=center,draw=blue!60!black,fill=blue!15,line width=1pt] at (%s,%s) {};"
             shape (texpresso-view--number (texpresso-view--shape-text-width shape 24))
             (texpresso-view--number (car place)) (texpresso-view--number (cdr place))))
    (texpresso-view--draw-page)))

(defun texpresso-view-insert-line (heads)
  "Put a line with the arrow HEADS (- for none) where the slide was last pressed.
It lies flat; drag its ends where they go."
  (interactive (list (cdr (assoc (completing-read "Line: " texpresso-view-line-kinds nil t)
                                 texpresso-view-line-kinds))))
  (let ((place (texpresso-view--place)))
    (texpresso-view--insert-object
     (format "\\node[tv,tv line={%s,line width=1.5pt},minimum width=24\\tvu] at (%s,%s) {};"
             heads (texpresso-view--number (car place)) (texpresso-view--number (cdr place))))
    (texpresso-view--draw-page)))

(defun texpresso-view--shape-items ()
  "The menu items that put a shape on the slide."
  (mapcar (lambda (s) (vector (car s) (lambda () (interactive) (texpresso-view-insert-shape (cdr s))) t))
          texpresso-view-shapes))

(defun texpresso-view--line-items ()
  "The menu items that put a line on the slide."
  (mapcar (lambda (l) (vector (car l) (lambda () (interactive) (texpresso-view-insert-line (cdr l))) t))
          texpresso-view-line-kinds))

(defun texpresso-view-shape-menu (event)
  "The toolbar's shape menu, at the click EVENT: shapes, and tables."
  (interactive "e")
  (popup-menu (easy-menu-create-menu "Shape" (append (texpresso-view--shape-items)
                                                     (list "---" (cons "Table" (texpresso-view--table-items)))))
              event))

(defun texpresso-view-line-menu (event)
  "The toolbar's line menu, at the click EVENT."
  (interactive "e")
  (popup-menu (easy-menu-create-menu "Line" (texpresso-view--line-items)) event))

;;; Text typed on the slide: a small frame under the object, whose text
;;; goes into the node's braces in the source as it is typed, so the slide
;;; shows it at once.  It is LaTeX: RET ends a line with \\.  Esc, C-g or
;;; a press on the page ends.  Where no child frame can be made (a text
;;; terminal), the same buffer opens in a window under the page.

(defconst texpresso-view-text-buffer-name " *texpresso-view text*"
  "The buffer the text of an object is typed in.")

(defvar-local texpresso-view--text-target nil
  "Where the text typed here goes: (BUFFER BEG END), markers in BUFFER.")

(defun texpresso-view--text-region (statement)
  "Where STATEMENT's text is: (BEG . END) inside the braces after its place."
  (pcase-let ((`(,buf ,beg ,end) statement))
    (with-current-buffer buf
      (save-excursion
        (goto-char beg)
        (when (and (re-search-forward texpresso-view--at-regexp end t)
                   (re-search-forward "\\=[ \t\n]*{" end t))
          (let ((close (texpresso-view--group-end (1- (point)) ?\{ ?\})))
            (and close (<= close end) (cons (point) (1- close)))))))))

(defun texpresso-view-text-newline ()
  "End the line of text here: \\\\ in the source, and a new line."
  (interactive)
  (insert "\\\\\n"))

(defvar texpresso-view-text-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'texpresso-view-text-newline)
    (define-key map (kbd "<escape>") #'texpresso-view-text-done)
    (define-key map (kbd "C-g") #'texpresso-view-text-done)
    (define-key map (kbd "C-c C-c") #'texpresso-view-text-done)
    map)
  "Keys of the text typed on the slide.")

(define-derived-mode texpresso-view-text-mode text-mode "Slide text"
  "The text of an object on the slide, typed into its source as it is typed.
\\{texpresso-view-text-mode-map}"
  (setq-local mode-line-format nil)
  (setq-local header-line-format
              (propertize " Type: the slide shows it.  Esc: done" 'face 'shadow)))

(defun texpresso-view--text-changed (&rest _)
  "Put the text typed into the node it belongs to, in the source.
It runs in `after-change-functions', where Emacs runs no change hooks:
those of the source are run again, so that texpresso.el sends TeXpresso
the change."
  (pcase-let ((`(,src ,beg ,end) texpresso-view--text-target)
              (text (buffer-substring-no-properties (point-min) (point-max)))
              (inhibit-modification-hooks nil))
    (when (and (buffer-live-p src) (marker-buffer beg))
      (with-current-buffer src
        (unless (equal text (buffer-substring-no-properties beg end))
          (save-excursion
            (goto-char beg)
            (delete-region beg end)
            (insert text)))))))

(defun texpresso-view--image-xy (win)
  "Where the page's image is in WIN, in pixels from its text area: (X . Y)."
  (with-current-buffer (window-buffer win)
    (let ((posn (posn-at-point (1- (point-max)) win)))
      (or (and posn (posn-x-y posn)) (cons 0 0)))))

(defun texpresso-view--text-frame (buf)
  "A small frame showing BUF under the object selected; nil where none can be."
  (let ((win (texpresso-view--window))
        (box (texpresso-view--box)))
    (when (and win box (display-graphic-p (window-frame win)))
      (pcase-let* ((parent (window-frame win))
                   (`(,ex ,ey . ,_) (window-inside-pixel-edges win))
                   (`(,ix . ,iy) (texpresso-view--image-xy win))
                   (px (/ (nth 1 texpresso-view--png) 100.0))
                   (bottom (apply #'max (mapcar (lambda (c) (cdr (texpresso-view--global box (car c) (cdr c))))
                                                (list (cons (- (/ (nth 2 box) 2.0)) (/ (nth 3 box) 2.0))
                                                      (cons (/ (nth 2 box) 2.0) (/ (nth 3 box) 2.0))
                                                      (cons (- (/ (nth 2 box) 2.0)) (- (/ (nth 3 box) 2.0)))
                                                      (cons (/ (nth 2 box) 2.0) (- (/ (nth 3 box) 2.0)))))))
                   (width (max 300 (round (* (nth 2 box) px))))
                   (height (* 5 (frame-char-height parent)))
                   (left (max 0 (min (- (frame-inner-width parent) width 20)
                                     (round (+ ex ix (* (nth 0 box) px))))))
                   (top (max 0 (min (- (frame-inner-height parent) height 20)
                                    (round (+ ey iy (* bottom px) 8)))))
                   (frame (make-frame
                           `((parent-frame . ,parent) (minibuffer . nil) (undecorated . t)
                             (left . ,left) (top . ,top)
                             (width . (text-pixels . ,width)) (height . (text-pixels . ,height))
                             (no-other-frame . t) (unsplittable . t) (no-special-glyphs . t)
                             (child-frame-border-width . 1) (internal-border-width . 6)
                             (vertical-scroll-bars . nil) (horizontal-scroll-bars . nil)
                             (left-fringe . 0) (right-fringe . 0) (menu-bar-lines . 0)
                             (tool-bar-lines . 0) (tab-bar-lines . 0) (desktop-dont-save . t)
                             (visibility . nil)))))
        (let ((w (frame-root-window frame)))
          (set-window-buffer w buf)
          (set-window-dedicated-p w t))
        (make-frame-visible frame)
        (select-frame-set-input-focus frame)
        frame))))

(defun texpresso-view-edit-text ()
  "Type the text of the object selected on the slide, in a small box under it.
What is typed goes into the source at once, and the slide shows it;
Esc ends.  A picture is cropped instead."
  (interactive)
  (let* ((statement (texpresso-view--selected-statement))
         (region (and (memq (texpresso-view--kind statement) '(text shape))
                      (texpresso-view--text-region statement))))
    (cond
     ((eq (texpresso-view--kind statement) 'picture)
      (texpresso-view-crop))
     ((not region)
      (texpresso-view-edit-object))
     (t
      (texpresso-view-text-done)
      (let* ((src (car statement))
             (beg (with-current-buffer src (copy-marker (car region))))
             (end (with-current-buffer src (copy-marker (cdr region) t)))
             (text (with-current-buffer src (buffer-substring-no-properties beg end)))
             (buf (get-buffer-create texpresso-view-text-buffer-name))
             frame)
        (with-current-buffer buf
          (texpresso-view-text-mode)
          (let ((inhibit-modification-hooks t))
            (erase-buffer)
            (insert text))
          (setq texpresso-view--text-target (list src beg end))
          (add-hook 'after-change-functions #'texpresso-view--text-changed nil t)
          (if (equal text "Text")
              (texpresso-view--select-placeholder (point-min) (point-max))
            (goto-char (point-max))))
        (setq frame (condition-case nil (texpresso-view--text-frame buf) (error nil)))
        (unless (or frame noninteractive)
          (select-window (display-buffer-in-side-window buf '((side . bottom) (slot . 1)
                                                              (window-height . 5)))))
        (setq texpresso-view--editor (list frame buf beg end)))))))

(defun texpresso-view-text-done ()
  "End typing the text of an object on the slide."
  (interactive)
  (when texpresso-view--editor
    (pcase-let ((`(,frame ,buf ,beg ,end) texpresso-view--editor))
      (setq texpresso-view--editor nil)
      (when (frame-live-p frame)
        (delete-frame frame))
      (when (buffer-live-p buf)
        (let ((win (get-buffer-window buf t)))
          (when (window-live-p win) (delete-window win)))
        (kill-buffer buf))
      (set-marker beg nil)
      (set-marker end nil)
      (let ((win (texpresso-view--window)))
        (when (window-live-p win)
          (unless noninteractive
            (select-frame-set-input-focus (window-frame win)))
          (select-window win))))))

;;; Arranging: several objects selected (shift and a click, or a frame
;;; dragged around them on an empty spot), moved, formatted, copied and
;;; deleted together; aligned, spread evenly, centred on the slide; grouped,
;;; so that a click on one selects them all (a `tv group' key each); and
;;; guides that a dragged object snaps to: the slide's edges and middle,
;;; the other objects' edges and middles.

(defun texpresso-view--selection ()
  "The objects selected, in order: their numbers.
The others than `texpresso-view--selected' count only while it is the
one they were selected with."
  (and texpresso-view--selected
       (sort (delete-dups (cons texpresso-view--selected
                                (and (eql (car texpresso-view--also) texpresso-view--selected)
                                     (copy-sequence (cdr texpresso-view--also)))))
             #'<)))

(defun texpresso-view--select (ks)
  "Select the objects KS, the first of them the one the format bar shows."
  (setq texpresso-view--selected (car ks)
        texpresso-view--also (and ks (cons (car ks) (cdr ks)))
        texpresso-view--format-cache nil
        texpresso-view--toolbar-cache nil))

(defun texpresso-view--extent (box)
  "BOX's extent on the slide, turned as it is: (LEFT TOP RIGHT BOTTOM)."
  (pcase-let* ((`(,_ ,_ ,w ,h) box)
               (points (mapcar (lambda (c) (texpresso-view--global box (car c) (cdr c)))
                               (list (cons (- (/ w 2.0)) (- (/ h 2.0))) (cons (/ w 2.0) (- (/ h 2.0)))
                                     (cons (/ w 2.0) (/ h 2.0)) (cons (- (/ w 2.0)) (/ h 2.0))))))
    (list (apply #'min (mapcar #'car points)) (apply #'min (mapcar #'cdr points))
          (apply #'max (mapcar #'car points)) (apply #'max (mapcar #'cdr points)))))

(defun texpresso-view--slide-height ()
  "The slide's height in slide units, 100 being its width."
  (* 100.0 (/ (float (nth 2 texpresso-view--png)) (nth 1 texpresso-view--png))))

(defun texpresso-view--group-of (k)
  "The objects grouped with object K, itself included: their numbers."
  (let* ((statements (texpresso-view--frame-statements))
         (group (let ((s (nth (1- k) statements))) (and s (texpresso-view--option s "tv group")))))
    (if (not (stringp group))
        (list k)
      (let ((i 0) ks)
        (dolist (s statements)
          (setq i (1+ i))
          (when (equal (texpresso-view--option s "tv group") group)
            (push i ks)))
        (nreverse ks)))))

(defun texpresso-view-mouse-down-add (event)
  "Add the object under the mouse EVENT to those selected, or take it away."
  (interactive "e")
  (let* ((at (texpresso-view--event-units event))
         (hit (and at (texpresso-view--hit (car at) (cdr at)))))
    (texpresso-view-text-done)
    (when (and hit (null (cadr hit)))
      (select-window (posn-window (event-start event)))
      (let* ((group (texpresso-view--group-of (car hit)))
             (now (texpresso-view--selection)))
        (texpresso-view--select
         (if (memq (car hit) now)
             (seq-difference now group)
           (append now group))))
      (texpresso-view--draw-page))))

(defun texpresso-view--band (event)
  "Select the objects a frame dragged from the press EVENT touches.
Nil if the mouse was released without moving: the release is left to
its command then."
  (let* ((posn (event-start event))
         (win (posn-window posn))
         (xy (posn-x-y posn))
         (oxy (posn-object-x-y posn))
         (origin (cons (- (car xy) (car oxy)) (- (cdr xy) (cdr oxy))))
         (u (texpresso-view--units-per-pixel))
         (x0 (* (car oxy) u)) (y0 (* (cdr oxy) u))
         (mouse-fine-grained-tracking t)
         band ev)
    (cl-flet ((follow (p)
                (let ((pxy (posn-x-y p)))
                  (when (and pxy (eq (posn-window p) win))
                    (let ((mx (* (- (car pxy) (car origin)) u))
                          (my (* (- (cdr pxy) (cdr origin)) u)))
                      (when (or band (> (abs (- mx x0)) 0.5) (> (abs (- my y0)) 0.5))
                        (setq band (list (min x0 mx) (min y0 my) (abs (- mx x0)) (abs (- my y0))))))))))
      (unwind-protect
          (track-mouse
            (while (mouse-movement-p (setq ev (read-event)))
              (follow (event-start ev))
              (when band
                (setq texpresso-view--band band)
                (texpresso-view--draw-page))))
        (setq texpresso-view--band nil))
      (when (and (consp ev) (memq 'drag (event-modifiers ev)))
        (follow (event-end ev)))
      (if (not band)
          (progn (when ev (push ev unread-command-events)) nil)
        (pcase-let ((`(,bx ,by ,bw ,bh) band)
                    (ks nil))
          (dolist (object (texpresso-view--boxes))
            (pcase-let ((`(,l ,top ,r ,b) (texpresso-view--extent (cdr object))))
              (when (and (< l (+ bx bw)) (> r bx) (< top (+ by bh)) (> b by))
                (setq ks (append ks (texpresso-view--group-of (car object)))))))
          (texpresso-view--select (delete-dups ks))
          (texpresso-view--draw-page)
          t)))))

(defun texpresso-view--move-all (ks dx dy)
  "Move the objects KS by DX DY slide units."
  (dolist (statement (mapcar #'texpresso-view--statement ks))
    (when statement
      (texpresso-view--shift statement dx dy))))

(defun texpresso-view--guides-for (box others)
  "Where BOX, moved, snaps to the guides of OTHERS and of the slide.
OTHERS are extents, as `texpresso-view--extent' gives them.  Returns
\(DX DY GUIDES): the shift that snaps BOX, and the guides it snaps to,
\(x . X) or (y . Y)."
  (pcase-let* ((`(,l ,top ,r ,b) (texpresso-view--extent box))
               (reach 0.8)
               (height (texpresso-view--slide-height))
               (xs (append (list 0 50 100)
                           (apply #'append (mapcar (lambda (e) (list (nth 0 e) (/ (+ (nth 0 e) (nth 2 e)) 2.0) (nth 2 e)))
                                                   others))))
               (ys (append (list 0 (/ height 2) height)
                           (apply #'append (mapcar (lambda (e) (list (nth 1 e) (/ (+ (nth 1 e) (nth 3 e)) 2.0) (nth 3 e)))
                                                   others))))
               (best-x nil) (best-y nil))
    (dolist (mine (list l (/ (+ l r) 2.0) r))
      (dolist (x xs)
        (let ((d (- x mine)))
          (when (and (< (abs d) reach) (or (null best-x) (< (abs d) (abs (car best-x)))))
            (setq best-x (cons d x))))))
    (dolist (mine (list top (/ (+ top b) 2.0) b))
      (dolist (y ys)
        (let ((d (- y mine)))
          (when (and (< (abs d) reach) (or (null best-y) (< (abs d) (abs (car best-y)))))
            (setq best-y (cons d y))))))
    (list (if best-x (car best-x) 0) (if best-y (car best-y) 0)
          (append (and best-x (list (cons 'x (cdr best-x))))
                  (and best-y (list (cons 'y (cdr best-y))))))))

(defun texpresso-view-align (how)
  "Align the objects selected HOW: left, center, right, top, middle or bottom.
Several are aligned with each other; one alone with the slide."
  (let* ((ks (or (texpresso-view--selection) (user-error "No object selected on the page")))
         (boxes (texpresso-view--boxes))
         (extents (mapcar (lambda (k) (cons k (texpresso-view--extent (cdr (assq k boxes))))) ks))
         (whole (if (cdr ks)
                    (list (apply #'min (mapcar (lambda (e) (nth 1 e)) extents))
                          (apply #'min (mapcar (lambda (e) (nth 2 e)) extents))
                          (apply #'max (mapcar (lambda (e) (nth 3 e)) extents))
                          (apply #'max (mapcar (lambda (e) (nth 4 e)) extents)))
                  (list 0 0 100 (texpresso-view--slide-height)))))
    (dolist (e extents)
      (pcase-let ((`(,k ,l ,top ,r ,b) e)
                  (`(,wl ,wt ,wr ,wb) whole))
        (let ((dx (pcase how
                    ("left" (- wl l)) ("right" (- wr r))
                    ("center" (- (/ (+ wl wr) 2.0) (/ (+ l r) 2.0))) (_ 0)))
              (dy (pcase how
                    ("top" (- wt top)) ("bottom" (- wb b))
                    ("middle" (- (/ (+ wt wb) 2.0) (/ (+ top b) 2.0))) (_ 0))))
          (texpresso-view--move-all (list k) dx dy))))
    (texpresso-view--draw-page)))

(defun texpresso-view-center-on-slide (across)
  "Put the objects selected, together, in the middle of the slide.
With ACROSS `horizontally' or `vertically', in that direction only."
  (let* ((ks (or (texpresso-view--selection) (user-error "No object selected on the page")))
         (boxes (texpresso-view--boxes))
         (extents (mapcar (lambda (k) (texpresso-view--extent (cdr (assq k boxes)))) ks))
         (l (apply #'min (mapcar #'car extents)))
         (top (apply #'min (mapcar #'cadr extents)))
         (r (apply #'max (mapcar #'caddr extents)))
         (b (apply #'max (mapcar #'cadddr extents)))
         (dx (if (eq across 'vertically) 0 (- 50 (/ (+ l r) 2.0))))
         (dy (if (eq across 'horizontally) 0 (- (/ (texpresso-view--slide-height) 2) (/ (+ top b) 2.0)))))
    (texpresso-view--move-all ks dx dy)
    (texpresso-view--draw-page)))

(defun texpresso-view-distribute (across)
  "Spread the objects selected evenly, ACROSS `horizontally' or `vertically'.
The first and the last stay; the gaps between them become equal."
  (let* ((ks (texpresso-view--selection))
         (boxes (texpresso-view--boxes))
         (h (eq across 'horizontally))
         (extents (sort (mapcar (lambda (k) (cons k (texpresso-view--extent (cdr (assq k boxes))))) ks)
                        (lambda (a b) (< (if h (nth 1 a) (nth 2 a)) (if h (nth 1 b) (nth 2 b)))))))
    (unless (cddr extents)
      (user-error "Select three objects or more to spread them"))
    (let* ((lo (lambda (e) (if h (nth 1 e) (nth 2 e))))
           (hi (lambda (e) (if h (nth 3 e) (nth 4 e))))
           (sizes (apply #'+ (mapcar (lambda (e) (- (funcall hi e) (funcall lo e))) extents)))
           (span (- (funcall hi (car (last extents))) (funcall lo (car extents))))
           (gap (/ (- span sizes) (1- (length extents))))
           (pos (funcall lo (car extents))))
      (dolist (e extents)
        (let ((d (- pos (funcall lo e))))
          (texpresso-view--move-all (list (car e)) (if h d 0) (if h 0 d)))
        (setq pos (+ pos (- (funcall hi e) (funcall lo e)) gap))))
    (texpresso-view--draw-page)))

(defun texpresso-view-group ()
  "Group the objects selected: a click on one of them selects them all."
  (interactive)
  (let ((ks (texpresso-view--selection))
        (name (format "g%d" (random 100000))))
    (unless (cdr ks)
      (user-error "Select two objects or more to group them"))
    (dolist (statement (mapcar #'texpresso-view--statement ks))
      (texpresso-view--put-option statement "tv group" name))
    (setq texpresso-view--format-cache nil)
    (texpresso-view--draw-page)))

(defun texpresso-view-ungroup ()
  "Ungroup the objects selected."
  (interactive)
  (dolist (statement (mapcar #'texpresso-view--statement (texpresso-view--selection)))
    (texpresso-view--put-option statement "tv group" nil))
  (setq texpresso-view--format-cache nil)
  (texpresso-view--draw-page))

(defun texpresso-view--arrange-items ()
  "The menu items that arrange the objects selected."
  (let* ((ks (texpresso-view--selection))
         (grouped (seq-some (lambda (k) (let ((st (nth (1- k) (texpresso-view--frame-statements))))
                                          (and st (texpresso-view--option st "tv group"))))
                            ks)))
    (cl-flet ((item (name fn &optional on)
                (vector name (lambda () (interactive) (funcall fn)) (and ks (or on t)))))
      `(("Align"
         ,(item "Left" (lambda () (texpresso-view-align "left")))
         ,(item "Centre" (lambda () (texpresso-view-align "center")))
         ,(item "Right" (lambda () (texpresso-view-align "right")))
         "---"
         ,(item "Top" (lambda () (texpresso-view-align "top")))
         ,(item "Middle" (lambda () (texpresso-view-align "middle")))
         ,(item "Bottom" (lambda () (texpresso-view-align "bottom"))))
        ("Centre on the slide"
         ,(item "Both ways" (lambda () (texpresso-view-center-on-slide nil)))
         ,(item "Horizontally" (lambda () (texpresso-view-center-on-slide 'horizontally)))
         ,(item "Vertically" (lambda () (texpresso-view-center-on-slide 'vertically))))
        ("Spread evenly"
         ,(item "Horizontally" (lambda () (texpresso-view-distribute 'horizontally)) (cddr ks))
         ,(item "Vertically" (lambda () (texpresso-view-distribute 'vertically)) (cddr ks)))
        ("Order"
         ,(item "Bring to front" #'texpresso-view-bring-to-front)
         ,(item "Send to back" #'texpresso-view-send-to-back))
        ("Appear" ,@(texpresso-view--appear-items))
        ("Rotate"
         ,(item "A quarter to the left" #'texpresso-view-rotate-left)
         ,(item "A quarter to the right" #'texpresso-view-rotate-right)
         ,(item "Upright" (lambda () (texpresso-view-rotate-by
                                       (- (texpresso-view--angle (texpresso-view--selected-statement)))))))
        ("Opacity"
         ,@(mapcar (lambda (o) (item (format "%d%%" (* 100 o)) (lambda () (texpresso-view-set-opacity o))))
                   '(1 0.75 0.5 0.25)))
        ,(item "Group" #'texpresso-view-group (cdr ks))
        ,(item "Ungroup" #'texpresso-view-ungroup grouped)))))

(defun texpresso-view-arrange-menu (event)
  "The format bar's arrange menu, at the click EVENT."
  (interactive "e")
  (popup-menu (easy-menu-create-menu "Arrange" (texpresso-view--arrange-items)) event))

;;; The deck and its slides: presenting it full screen from the slide on
;;; display, skipping a slide (\begin{frame}<0>, so it makes no page), a
;;; slide's transition (beamer's \trans… commands, which viewers that
;;; know PDF transitions play), the deck's theme and colours (\usetheme,
;;; \usecolortheme); and objects that appear one step after another: a
;;; `tv appear' key on each, the steps registered by the layer's optional
;;; argument, \begin{tvlayer}[3], so that Beamer makes a page for each.

(defcustom texpresso-view-present-command
  "latexmk -pdf -synctex=1 -interaction=nonstopmode %s"
  "The command that makes the deck's PDF to present; %s is the root file.
It runs in the root file's folder, and the PDF is taken next to it."
  :type 'string
  :group 'tex)

(defcustom texpresso-view-present-viewer "zathura --mode=presentation --page=%p %f"
  "The command that shows the deck's PDF full screen.
%f is the PDF, %p the page to start from."
  :type 'string
  :group 'tex)

(defconst texpresso-view-present-buffer-name "*texpresso-view present*"
  "The buffer of the command making the PDF to present.")

(defun texpresso-view-present ()
  "Present the deck full screen, from the slide on display.
The deck's files are saved first (each one asked), then the PDF is made
with `texpresso-view-present-command' and shown with
`texpresso-view-present-viewer'."
  (interactive)
  (unless texpresso-view--root
    (user-error "No TeXpresso view open"))
  (let* ((root texpresso-view--root)
         (dir (file-name-directory root))
         (pdf (concat (file-name-sans-extension root) ".pdf"))
         (page (1+ (or texpresso-view--page 0)))
         (start (current-time))
         (default-directory dir)
         (log (get-buffer-create texpresso-view-present-buffer-name)))
    (save-some-buffers nil (lambda () (and buffer-file-name
                                           (file-in-directory-p buffer-file-name dir))))
    (with-current-buffer log
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (message "Making the PDF to present…")
    (make-process
     :name "texpresso-view-present"
     :buffer log
     :command (list shell-file-name shell-command-switch
                    (format texpresso-view-present-command
                            (shell-quote-argument (file-name-nondirectory root))))
     :sentinel
     (lambda (process _event)
       (when (memq (process-status process) '(exit signal))
         (if (and (file-exists-p pdf)
                  (or (eql (process-exit-status process) 0)
                      (time-less-p start (file-attribute-modification-time
                                          (file-attributes pdf)))))
             (let ((default-directory dir))
               (message "Presenting %s from page %d" (file-name-nondirectory pdf) page)
               (start-process-shell-command
                "texpresso-view-viewer" nil
                (format-spec texpresso-view-present-viewer
                             `((?f . ,(shell-quote-argument pdf)) (?p . ,page)))))
           (message "The PDF could not be made: see the buffer %s" (buffer-name log))))))))

(defun texpresso-view--frame-skipped-p (buf pos)
  "Non-nil if the frame at POS of BUF is skipped: \\begin{frame}<0>."
  (with-current-buffer buf
    (save-excursion
      (goto-char pos)
      (looking-at "\\\\begin{frame}<0>"))))

(defun texpresso-view--toggle-skip (buf pos)
  "Skip the frame at POS of BUF, or show it again if it is skipped."
  (with-current-buffer buf
    (save-excursion
      (goto-char pos)
      (if (looking-at "\\\\begin{frame}\\(<0>\\)")
          (delete-region (match-beginning 1) (match-end 1))
        (when (looking-at "\\\\begin{frame}")
          (goto-char (match-end 0))
          (insert "<0>"))))))

(defun texpresso-view-skip-slide ()
  "Skip the slide on display.
It stays in the source and in the strip, not in the deck.  Done again
from the strip, it shows the slide again."
  (interactive)
  (let ((start (or (texpresso-view--frame-marker)
                   (user-error "This slide has no \\begin{frame} of its own in the deck"))))
    (texpresso-view--toggle-skip (marker-buffer start) start)
    (texpresso-view--strip-schedule)
    (message "Slide skipped: the strip shows it again (right click)")))

(defun texpresso-view-slides-skip ()
  "Skip the strip's slide at point, or show it again if it is skipped."
  (interactive)
  (let ((frame (nth (texpresso-view--slide-at) texpresso-view--strip-frames)))
    (texpresso-view--toggle-skip (nth 0 frame) (nth 1 frame))
    (texpresso-view--strip-draw)))

(defconst texpresso-view-transitions
  '(("None" . nil) ("Fade" . "\\transfade") ("Dissolve" . "\\transdissolve")
    ("Wipe" . "\\transwipe") ("Push" . "\\transpush") ("Cover" . "\\transcover")
    ("Split" . "\\transsplitverticalout") ("Box" . "\\transboxout") ("Glitter" . "\\transglitter"))
  "The transitions a slide can have: (NAME . BEAMER-COMMAND).")

(defun texpresso-view-set-transition (command)
  "Give the slide on display the transition COMMAND, as \\transfade; nil: none.
It is a line right after the frame's first."
  (pcase-let ((`(,buf ,beg ,end) (or (texpresso-view--frame)
                                     (user-error "No frame found in the source for this slide"))))
    (with-current-buffer buf
      (save-excursion
        (goto-char beg)
        (if (re-search-forward "^[ \t]*\\\\trans[a-z]+\\(?:<[^>\n]*>\\)?\\(?:\\[[^]\n]*\\]\\)?[ \t]*\n" end t)
            (replace-match (if command (concat "  " command "\n") "") t t)
          (when command
            (goto-char beg)
            (forward-line 1)
            (insert "  " command "\n")))))))

(defconst texpresso-view-themes
  '("default" "AnnArbor" "Antibes" "Bergen" "Berkeley" "Berlin" "Boadilla" "CambridgeUS"
    "Copenhagen" "Darmstadt" "Dresden" "Frankfurt" "Goettingen" "Hannover" "Ilmenau"
    "JuanLesPins" "Luebeck" "Madrid" "Malmoe" "Marburg" "Montpellier" "PaloAlto" "Pittsburgh"
    "Rochester" "Singapore" "Szeged" "Warsaw" "metropolis")
  "Beamer's themes, and Metropolis.")

(defconst texpresso-view-color-themes
  '("default" "albatross" "beaver" "beetle" "crane" "dolphin" "dove" "fly" "lily" "orchid"
    "rose" "seagull" "seahorse" "whale" "wolverine")
  "Beamer's colour themes.")

(defun texpresso-view--set-preamble-command (command value)
  "Make the deck's \\COMMAND{VALUE}: replace the first, or add one.
It is looked for in the root file and the files it reads; a new one goes
right before \\begin{document}."
  (let* ((root (texpresso-view--root-buffer))
         (buffers (cons root (mapcar (lambda (f) (or (find-buffer-visiting f) (find-file-noselect f)))
                                     (texpresso-view--input-files root))))
         (re (concat "^[ \t]*\\\\" command "\\(?:\\[[^]\n]*\\]\\)?{\\([^}\n]*\\)}")))
    (unless (seq-some (lambda (b)
                        (with-current-buffer b
                          (save-excursion
                            (goto-char (point-min))
                            (when (re-search-forward re nil t)
                              (replace-match value t t nil 1)
                              t))))
                      buffers)
      (with-current-buffer root
        (save-excursion
          (goto-char (point-min))
          (unless (re-search-forward "^[ \t]*\\\\begin{document}" nil t)
            (user-error "No \\begin{document} in %s" (file-name-nondirectory texpresso-view--root)))
          (goto-char (line-beginning-position))
          (insert (format "\\%s{%s}\n" command value)))))))

(defun texpresso-view-set-theme (theme)
  "Give the deck Beamer's THEME."
  (interactive (list (completing-read "Theme: " texpresso-view-themes nil t)))
  (texpresso-view--set-preamble-command "usetheme" theme))

(defun texpresso-view-set-color-theme (theme)
  "Give the deck Beamer's colour THEME."
  (interactive (list (completing-read "Colours: " texpresso-view-color-themes nil t)))
  (texpresso-view--set-preamble-command "usecolortheme" theme))

(defun texpresso-view--update-steps ()
  "Give the layer of the slide on display as many steps as its objects appear in."
  (pcase-let ((`(,buf ,beg ,end) (texpresso-view--frame)))
    (when buf
      (let ((steps (apply #'max 1 (mapcar (lambda (s)
                                            (let ((v (texpresso-view--option s "tv appear")))
                                              (if (stringp v) (string-to-number v) 1)))
                                          (texpresso-view--frame-statements)))))
        (with-current-buffer buf
          (save-excursion
            (goto-char beg)
            (when (re-search-forward "\\\\begin{tvlayer}\\(?:\\[[0-9]+\\]\\)?" end t)
              (replace-match (if (> steps 1) (format "\\begin{tvlayer}[%d]" steps)
                               "\\begin{tvlayer}")
                             t t))))))))

(defun texpresso-view-set-appear (step)
  "Make the objects selected appear at STEP of their slide: 1 with it.
Each step is a click of the presentation, a page of the deck."
  (texpresso-view--format
   (lambda (statement _kind)
     (texpresso-view--put-option statement "tv appear" (and (> step 1) (number-to-string step)))))
  (texpresso-view--update-steps))

(defun texpresso-view--appear-items ()
  "The menu items that make the objects selected appear at a step."
  (mapcar (lambda (step)
            (vector (if (= step 1) "With the slide" (format "At click %d" (1- step)))
                    (lambda () (interactive) (texpresso-view-set-appear step))
                    'texpresso-view--selected))
          '(1 2 3 4 5 6)))

(defun texpresso-view--deck-items ()
  "The menu items about the deck: transition, theme, colours, presenting."
  `(("Transition"
     ,@(mapcar (lambda (tr) (vector (car tr) (lambda () (interactive) (texpresso-view-set-transition (cdr tr))) t))
               texpresso-view-transitions))
    ("Theme"
     ,@(mapcar (lambda (th) (vector th (lambda () (interactive) (texpresso-view-set-theme th)) t))
               texpresso-view-themes))
    ("Colours"
     ,@(mapcar (lambda (th) (vector th (lambda () (interactive) (texpresso-view-set-color-theme th)) t))
               texpresso-view-color-themes))
    ["Skip this slide" texpresso-view-skip-slide t]
    "---"
    ["Present from this slide" texpresso-view-present t]))

(defun texpresso-view-slides-context-menu (event)
  "The menu of the strip's slide right-clicked in EVENT."
  (interactive "e")
  (let* ((posn (event-start event))
         (pos (posn-point posn))
         (i (and pos (get-text-property pos 'texpresso-view-slide (window-buffer (posn-window posn))))))
    (when i
      (select-window (posn-window posn))
      (texpresso-view--strip-goto i)
      (let* ((frame (nth i texpresso-view--strip-frames))
             (skipped (texpresso-view--frame-skipped-p (nth 0 frame) (nth 1 frame))))
        (popup-menu
         (easy-menu-create-menu
          "Slide"
          `(["Show it" texpresso-view-slides-show (not ,skipped)]
            [,(if skipped "Show it again in the deck" "Skip it") texpresso-view-slides-skip t]
            ["Duplicate" texpresso-view-slides-duplicate t]
            ["Delete" texpresso-view-slides-delete t]
            ("New slide after it"
             ,@(texpresso-view--layout-items #'texpresso-view-slides-new))
            "---"
            ["Move up" texpresso-view-slides-move-up t]
            ["Move down" texpresso-view-slides-move-down t]))
         event)))))

;;; Cropping a picture, as Google Slides does: in crop mode its handles
;;; cut its sides, the picture keeping its size and place, a dashed outline
;;; showing all of it.  The crop is \tvcrop{L}{B}{R}{T}{…} around its
;;; \includegraphics, in fractions of the picture: a TikZ clip, defined in
;;; the preamble block (graphicx's and adjustbox's clip made TeXpresso die).  And tables: a tabular in a node, its cells
;;; typed in the box a double click opens.

(defconst texpresso-view--crop-regexp
  "\\\\tvcrop{\\([0-9.]+\\)}{\\([0-9.]+\\)}{\\([0-9.]+\\)}{\\([0-9.]+\\)}{"
  "A picture's crop in its node: the start of the \\tvcrop around it.")

(defun texpresso-view--crop (statement)
  "How STATEMENT's picture is cropped: (LEFT BOTTOM RIGHT TOP), fractions of it."
  (pcase-let ((`(,buf ,beg ,end) statement))
    (with-current-buffer buf
      (save-excursion
        (goto-char beg)
        (if (re-search-forward texpresso-view--crop-regexp end t)
            (mapcar (lambda (i) (string-to-number (match-string i))) '(1 2 3 4))
          (list 0 0 0 0))))))

(defun texpresso-view--set-crop (statement crop)
  "Crop STATEMENT's picture by CROP, (LEFT BOTTOM RIGHT TOP); all zero: uncropped."
  (pcase-let ((`(,buf ,beg ,end) statement)
              (zero (seq-every-p (lambda (v) (< v 0.0005)) crop))
              (text (apply #'format "\\tvcrop{%s}{%s}{%s}{%s}{"
                           ;; to a hundredth of the picture
                           (mapcar (lambda (v) (format "%g" (/ (round (* 100 (max 0 v))) 100.0)))
                                   crop))))
    (with-current-buffer buf
      (save-excursion
        (goto-char beg)
        (cond
         ((re-search-forward texpresso-view--crop-regexp end t)
          (if (not zero)
              (unless (equal (match-string 0) text)
                (replace-match text t t))
            (let* ((from (match-beginning 0))
                   (open (1- (match-end 0)))
                   (close (texpresso-view--group-end open ?\{ ?\})))
              (when close
                (delete-region (1- close) close)
                (delete-region from (1+ open))))))
         ((and (not zero) (re-search-forward "\\\\includegraphics" end t))
          (let ((from (match-beginning 0)))
            (when (looking-at "[ \t]*\\[")
              (goto-char (texpresso-view--group-end (1- (match-end 0)) ?\[ ?\])))
            (when (looking-at "[ \t]*{")
              (goto-char (texpresso-view--group-end (1- (match-end 0)) ?\{ ?\}))
              (insert "}")
              (goto-char from)
              (insert text)))))))))

(defun texpresso-view--cropped (box crop handle mx my)
  "BOX, the part shown of a picture cropped by CROP, its HANDLE dragged to MX MY.
Returns (BOX . CROP): the picture keeps its size and place, the side
dragged shows more or less of it, a twentieth of it at least."
  (pcase-let* ((`(,_ ,_ ,w ,h ,a ,kind) box)
               (`(,l ,b ,r ,top) crop)
               (fw (/ w (max 0.05 (- 1 l r))))
               (fh (/ h (max 0.05 (- 1 b top))))
               (left (- (- (/ w 2.0)) (* l fw)))
               (upper (- (- (/ h 2.0)) (* top fh)))
               (p (texpresso-view--local box mx my)))
    (when (memq handle '(nw w sw))
      (setq l (min (max 0 (/ (- (car p) left) fw)) (- 1 r 0.05))))
    (when (memq handle '(ne e se))
      (setq r (min (max 0 (/ (- (+ left fw) (car p)) fw)) (- 1 l 0.05))))
    (when (memq handle '(nw n ne))
      (setq top (min (max 0 (/ (- (cdr p) upper) fh)) (- 1 b 0.05))))
    (when (memq handle '(sw s se))
      (setq b (min (max 0 (/ (- (+ upper fh) (cdr p)) fh)) (- 1 top 0.05))))
    (let* ((x0 (+ left (* l fw))) (x1 (- (+ left fw) (* r fw)))
           (y0 (+ upper (* top fh))) (y1 (- (+ upper fh) (* b fh)))
           (c (texpresso-view--global box (/ (+ x0 x1) 2.0) (/ (+ y0 y1) 2.0)))
           (nw (- x1 x0)) (nh (- y1 y0)))
      (cons (list (- (car c) (/ nw 2.0)) (- (cdr c) (/ nh 2.0)) nw nh a kind)
            (list l b r top)))))

(defun texpresso-view--crop-ghost (box crop)
  "The corners of all of the picture BOX shows a part of, cropped by CROP.
On the slide, as BOX is turned."
  (pcase-let* ((`(,_ ,_ ,w ,h) box)
               (`(,l ,b ,r ,top) crop)
               (fw (/ w (max 0.05 (- 1 l r))))
               (fh (/ h (max 0.05 (- 1 b top))))
               (left (- (- (/ w 2.0)) (* l fw)))
               (upper (- (- (/ h 2.0)) (* top fh))))
    (mapcar (lambda (c) (texpresso-view--global box (car c) (cdr c)))
            (list (cons left upper) (cons (+ left fw) upper)
                  (cons (+ left fw) (+ upper fh)) (cons left (+ upper fh))))))

(defun texpresso-view-crop ()
  "Crop the picture selected with its handles, or end cropping it."
  (interactive)
  (let ((statement (texpresso-view--selected-statement)))
    (unless (eq (texpresso-view--kind statement) 'picture)
      (user-error "Only a picture can be cropped"))
    (setq texpresso-view--cropping (and (not (eql texpresso-view--cropping texpresso-view--selected))
                                        texpresso-view--selected)
          texpresso-view--format-cache nil)
    (texpresso-view--draw-page)
    (when texpresso-view--cropping
      (message "Drag the handles to crop; Esc or a click elsewhere when done"))))

(defun texpresso-view-uncrop ()
  "Show all of the picture selected again."
  (interactive)
  (texpresso-view--format
   (lambda (statement kind)
     (when (eq kind 'picture)
       (texpresso-view--set-crop statement '(0 0 0 0))))))

(defun texpresso-view-insert-table (rows columns)
  "Put a table of ROWS by COLUMNS on the slide where it was last pressed.
Its cells are LaTeX: a double click opens them for typing."
  (let* ((place (texpresso-view--place))
         (row (concat (string-join (make-list columns "Cell") " & ") " \\\\ \\hline")))
    (texpresso-view--insert-object
     (format "\\node[tv] at (%s,%s) {\\begin{tabular}{|%s|}\\hline %s\\end{tabular}};"
             (texpresso-view--number (car place)) (texpresso-view--number (cdr place))
             (string-join (make-list columns "l") "|")
             (string-join (make-list rows row) " ")))
    (texpresso-view--draw-page)))

(defun texpresso-view--table-items ()
  "The menu items that put a table on the slide."
  (mapcar (lambda (size)
            (vector (format "%d × %d" (car size) (cdr size))
                    (lambda () (interactive) (texpresso-view-insert-table (car size) (cdr size)))
                    t))
          '((2 . 2) (2 . 3) (3 . 2) (3 . 3) (3 . 4) (4 . 3) (4 . 4) (5 . 3))))


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
        ;; the slides are after \begin{document}: the frames before it, and in
        ;; the files read there, are macros' (\AtBeginSection); a file with one
        ;; of its own (docmute's decks in a course) also starts after it
        (re-search-forward "^[ \t]*\\\\begin{document}" nil t)
        (let (frames)
          ;; a file read by \input, \include or a command of the deck's own
          ;; (\deck{chapter}): a command alone on its line naming a .tex file
          (while (re-search-forward
                  "^[ \t]*\\\\\\(?:\\(begin{frame}\\)\\|[a-zA-Z]+\\*?{\\([^{}\n]+\\)}[ \t]*\\(?:%.*\\)?$\\)" nil t)
            (if (match-beginning 1)
                (let ((beg (match-beginning 0)))
                  (when (re-search-forward "\\\\end{frame}" nil t)
                    (push (list buf beg (point) (texpresso-view--frame-title beg (point)))
                          frames)))
              (let ((file (texpresso-view--input-target (match-string 2))))
                (when (and file (< depth 5) (string-suffix-p ".tex" file))
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
                        (if (texpresso-view--frame-skipped-p (nth 0 frame) (nth 1 frame))
                            (propertize " (skipped)" 'face 'shadow)
                          "")
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
  (define-key map [down-mouse-3] #'texpresso-view-slides-context-menu)
  (define-key map [mouse-3] #'ignore)
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
  (define-key map (kbd "C-y") #'texpresso-view-paste)
  (define-key map (kbd "s") #'texpresso-view-slides)
  (define-key map [down-mouse-3] #'texpresso-view-context-menu)
  (define-key map [mouse-3] #'ignore)
  ;; shift and a click adds to the objects selected; on a slide a drag on an
  ;; empty spot frames objects, so Meta and a drag copies the page's text there
  (define-key map (kbd "<f5>") #'texpresso-view-present)
  (define-key map [S-down-mouse-1] #'texpresso-view-mouse-down-add)
  (define-key map [S-mouse-1] #'ignore)
  (define-key map [S-drag-mouse-1] #'ignore)
  (define-key map [M-down-mouse-1] #'ignore)
  (define-key map [M-mouse-1] #'texpresso-view-click)
  (define-key map [M-drag-mouse-1] #'texpresso-view-select)
  map)

(defvar texpresso-view-mode-map (make-sparse-keymap)
  "Keys of the page window.")

(texpresso-view--define-keys texpresso-view-mode-map)

(easy-menu-define texpresso-view-slides-menu texpresso-view-mode-map
  "The Slides menu of the page window, on a Beamer deck."
  '("Slides"
    :visible (texpresso-view--deck-p)
    ["Text box" texpresso-view-add-text t]
    ("Picture"
     ["From your computer…" texpresso-view-insert-image t]
     ["Recent pictures…" texpresso-view-pictures t]
     ["Paste from the clipboard" texpresso-view-paste-image t])
    ("Shape" :filter (lambda (_) (texpresso-view--shape-items)))
    ("Line" :filter (lambda (_) (texpresso-view--line-items)))
    ("Table" :filter (lambda (_) (texpresso-view--table-items)))
    "---"
    ["Edit text" texpresso-view-edit-text texpresso-view--selected]
    ["Rotate left" texpresso-view-rotate-left texpresso-view--selected]
    ["Rotate right" texpresso-view-rotate-right texpresso-view--selected]
    ["Bold" texpresso-view-toggle-bold texpresso-view--selected]
    ["Italic" texpresso-view-toggle-italic texpresso-view--selected]
    ("Arrange" :filter (lambda (_) (texpresso-view--arrange-items)))
    "---"
    ["Undo" texpresso-view-undo t]
    ["Redo" texpresso-view-redo t]
    ["Cut" texpresso-view-cut-object texpresso-view--selected]
    ["Copy" texpresso-view-copy-object texpresso-view--selected]
    ["Paste" texpresso-view-paste t]
    ["Duplicate" texpresso-view-duplicate-object texpresso-view--selected]
    ["Delete" texpresso-view-delete-object texpresso-view--selected]
    ("Order"
     ["Bring to front" texpresso-view-bring-to-front texpresso-view--selected]
     ["Bring forward" texpresso-view-raise-object texpresso-view--selected]
     ["Send backward" texpresso-view-lower-object texpresso-view--selected]
     ["Send to back" texpresso-view-send-to-back texpresso-view--selected])
    "---"
    ("New slide"
     :filter (lambda (_) (texpresso-view--layout-items #'texpresso-view-new-slide)))
    ["Duplicate this slide" texpresso-view-duplicate-slide t]
    ["Delete this slide" texpresso-view-delete-slide t]
    ["Slide strip" texpresso-view-slides :style toggle
     :selected (texpresso-view--strip-window)]
    ("Deck" :filter (lambda (_) (texpresso-view--deck-items)))))

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
        texpresso-view--frame-start nil
        texpresso-view--deck nil
        texpresso-view--toolbar-cache nil
        texpresso-view--format-cache nil
        texpresso-view--palette nil
        texpresso-view--also nil
        texpresso-view--cropping nil
        texpresso-view--outlines nil
        texpresso-view--band nil
        texpresso-view--guides nil)
  (texpresso-view-text-done)
  (texpresso-view-pictures-close)
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
        ;; the buffer outlives a switch to another document: its prompts
        ;; (a picture's, `i') start in this one's folder
        (setq default-directory (file-name-directory root))
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
