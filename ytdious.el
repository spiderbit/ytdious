;;; ytdious.el --- Query / Preview YouTube via Invidious -*- lexical-binding: t; -*-

;; This file is NOT part of Emacs.

;; This  program is  free  software; you  can  redistribute it  and/or
;; modify it  under the  terms of  the GNU  General Public  License as
;; published by the Free Software  Foundation; either version 2 of the
;; License, or (at your option) any later version.

;; This program is distributed in the hope that it will be useful, but
;; WITHOUT  ANY  WARRANTY;  without   even  the  implied  warranty  of
;; MERCHANTABILITY or FITNESS  FOR A PARTICULAR PURPOSE.   See the GNU
;; General Public License for more details.

;; You should have  received a copy of the GNU  General Public License
;; along  with  this program;  if  not,  write  to the  Free  Software
;; Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111-1307
;; USA

;; Author: Stefan Huchler
;;      Gabriele Rastello
;; Version: 0.1.0
;; Keywords: youtube matching multimedia
;; URL: https://github.com/spiderbit/ytdious
;; License: GNU General Public License >= 3
;; Package-Requires: ((emacs "25.3") (s "1.12.0"))

;;; Commentary:

;; This package provide a major mode to search YouTube videos via a tabulated list
;; and allows to open multiple search buffers at the same time, it comes with features like thumbnail pictures and sorting / limiting by time periods.
;; Visit Readme for more information.
;;
;; ytdious is based/forked on/from ytel but ads some nice features to make it more usable for browsing and binch watching. (more here: https://github.com/gRastello/ytel).
;;
;; ytdious works by querying YouTube via the Invidious apis (learn more on that here:
;; https://github.com/omarroth/invidious).

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'ring)
(require 's)

(defgroup ytdious ()
  "An Emacs Youtube \"front-end\"."
  :group 'comm)

(defvar ytdious-sort-options (ring-convert-sequence-to-ring
			   '(relevance rating upload_date view_count))
  "Availible sort options.")

(defvar ytdious-date-options (ring-convert-sequence-to-ring '(hour today week month year all))
  "Availible date options.")

(defvar ytdious-invidious-api-url "https://invidio.us"
  "Url to an Invidious instance.")

(defvar ytdious-invidious-default-query-fields "author,lengthSeconds,title,videoId,authorId,viewCount,published"
  "Default fields of interest for video search.")

(defvar-local ytdious-videos '()
  "List of videos currently on display.")

(defvar ytdious-published-date-time-string "%Y-%m-%d"
  "Time-string used to render the published date of the video.
See `format-time-string' for information on how to edit this variable.")

(defvar-local ytdious-sort-criterion 'relevance
  "Criterion to date limit the results of the search query.")

(defvar-local ytdious-date-criterion 'year
  "Criterion to date limit the results of the search query.")

(defvar-local ytdious-current-page 1
  "Current page of the current `ytdious-search-term'")

(defvar-local ytdious-search-term ""
  "Current search string as used by `ytdious-search'")

(defvar ytdious-author-name-reserved-space 20
  "Number of characters reserved for the channel's name in the *ytdious* buffer.
Note that there will always 3 extra spaces for eventual dots (for names that are
too long).")

(defvar ytdious-title-video-reserved-space 100
  "Number of characters reserved for the video title in the *ytdious* buffer.
Note that there will always 3 extra spaces for eventual dots (for names that are
too long).")

(defface ytdious-video-published-face
  '((((class color) (background light)) (:foreground "#a0a"))
    (((class color) (background dark))  (:foreground "#7a7")))
  "Face used for the video published date.")

(defface ytdious-channel-name-face
  '((((class color) (background light)) (:foreground "#aa0"))
    (((class color) (background dark))  (:foreground "#ff0")))
  "Face used for channel names.")

(defface ytdious-video-length-face
  '((((class color) (background light)) (:foreground "#aaa"))
    (((class color) (background dark))  (:foreground "#77a")))
  "Face used for the video length.")

(defface ytdious-video-view-face
  '((((class color) (background light)) (:foreground "#00a"))
    (((class color) (background dark))  (:foreground "#aa7")))
  "Face used for the video views.")

(defvar ytdious-mode-map
  (let ((map (make-sparse-keymap)))
    (suppress-keymap map)
    (define-key map "q" #'ytdious-quit)
    (define-key map "h" #'describe-mode)
    (define-key map "n" #'next-line)
    (define-key map "p" #'previous-line)
    (define-key map "d" #'ytdious-rotate-date)
    (define-key map "D" #'ytdious-rotate-date-backwards)
    (define-key map "r" #'ytdious-rotate-sort)
    (define-key map "R" #'ytdious-rotate-sort-backwards)
    (define-key map "t" #'ytdious-display-full-title)
    (define-key map "s" #'ytdious-search)
    (define-key map ">" #'ytdious-search-next-page)
    (define-key map "<" #'ytdious-search-previous-page)
    (define-key map [remap next-line] #'ytdious-next-line)
    (define-key map [remap previous-line] #'ytdious-previous-line)
    map)
  "Keymap for `ytdious-mode'.")

(define-derived-mode ytdious-mode tabulated-list-mode "ytdious"
  "Major Mode for ytdious.
Key bindings:
\\{ytdious-mode-map}"
  (setq-local split-height-threshold 22)
  (setq-local revert-buffer-function #'ytdious--draw-buffer))

(defun ytdious-show-image-asyncron ()
    "Display Thumbnail and Titel of video on point."
    (interactive)
    (if-let ((video (ytdious-get-current-video))
	     (id    (ytdious-video-id-fun video))
	     (title (assoc-default 'title (ytdious-get-current-video))))
	(url-retrieve
	 (format "%s/vi/%s/mqdefault.jpg"
		 ytdious-invidious-api-url id)
	 'ytdious-display-video-detail-popup (list title))))

(defun ytdious-display-video-detail-popup (_status title)
    "Create or raise popup-buffer with video details.
Argument _STATUS event lists of http request
for further details look at `url-retrieve'.
Argument TITLE video title."
    (let* ((buffer (current-buffer))
	   (buf-name "ytdious: Video Details")
	   (popup-buffer (get-buffer-create buf-name))
	   (data (with-current-buffer buffer
		   (search-forward "\n\n")
		   (buffer-substring (point) (point-max))))
	   (image (create-image data nil t)))
      (kill-buffer buffer)
      (let* ((inhibit-read-only t))
	(with-current-buffer popup-buffer
			     (kill-region (point-min) (point-max))
			     (insert (format "\n%s\n\n" title))
			     (insert-image image)
			     (help-mode)))
      (unless (get-buffer-window popup-buffer (selected-frame))
	(display-buffer-pop-up-window popup-buffer nil))))

(defun ytdious-next-line ()
  "Wrapper for the `next-line' function."
  (interactive)
  (forward-line)
  (ytdious-show-image-asyncron))

(defun ytdious-previous-line ()
  "Wrapper for the `previous-line' function."
  (interactive)
  (forward-line -1)
  (ytdious-show-image-asyncron))

(defun ytdious-quit ()
  "Quit ytdious buffer."
  (interactive)
  (if-let ((popup (get-buffer "ytdious: Video Details")))
      (progn (delete-window (get-buffer-window popup))
	     (kill-buffer popup))
    (quit-window)))

(defun ytdious--format-author (name)
  "Format a channel NAME to be inserted in the *ytdious* buffer."
  (propertize name 'face 'ytdious-channel-name-face))

(defun ytdious--format-video-length (seconds)
  "Given an amount of SECONDS, format it nicely to be inserted in the *ytdious* buffer."
  (let ((formatted-string (concat (format-seconds "%.2h" seconds)
				  ":"
				  (format-seconds "%.2m" (mod seconds 3600))
				  ":"
				  (format-seconds "%.2s" (mod seconds 60)))))
    (propertize formatted-string 'face 'ytdious-video-length-face)))

(defun ytdious--format-video-views (views)
  "Format video VIEWS to be inserted in the *ytdious* buffer."
  (propertize (number-to-string views) 'face 'ytdious-video-view-face))

(defun ytdious--format-video-published (published)
  "Format video PUBLISHED date to be inserted in the *ytdious* buffer."
  (propertize (format-time-string ytdious-published-date-time-string (seconds-to-time published))
	      'face 'ytdious-video-published-face))

(defun ytdious--create-entry (video)
  "Create tabulated-list VIDEO entry."
  (list (assoc-default 'videoId video)
	(vector (ytdious--format-video-published (assoc-default 'published video))
		(ytdious--format-author (assoc-default 'author video))
		(ytdious--format-video-length (assoc-default 'lengthSeconds video))
		(assoc-default 'title video)
		(ytdious--format-video-views (assoc-default 'viewCount video)))))

(defun ytdious--draw-buffer (&optional _arg _noconfirm)
  "Draw a list of videos.
Optional argument _ARG revert expects this param.
Optional argument _NOCONFIRM revert expects this param."
  (interactive)
  (let* ((search-string (propertize ytdious-search-term 'face 'ytdious-video-published-face))
	 (page-number (propertize (number-to-string ytdious-current-page)
				  'face 'ytdious-video-published-face))
	 (date-limit (propertize (symbol-name ytdious-date-criterion)
				 'face 'ytdious-video-published-face))
	 (sort-strings '(upload_date "date" view_count "views"
				     rating "rating" relevance "relevance"))
	 (sort-limit (propertize (plist-get sort-strings ytdious-sort-criterion)
				 'face 'ytdious-video-published-face))
	 (new-buffer-name (format "ytdious: %s" search-string)))
    (setq tabulated-list-format `[("Date" 10 t)
				  ("Author" ,ytdious-author-name-reserved-space t)
				  ("Length" 8 t) ("Title"  ,ytdious-title-video-reserved-space t)
				  ("Views" 10 t . (:right-align t))])
    (setf ytdious-videos (ytdious--query ytdious-search-term ytdious-current-page))

    (if (get-buffer new-buffer-name)
	(switch-to-buffer (get-buffer-create new-buffer-name))
      (rename-buffer new-buffer-name))

    (setq-local mode-line-misc-info `(("page:" ,page-number)
				      (" date:" ,date-limit)
				      (" sort:" ,sort-limit)))
    (setq tabulated-list-entries (mapcar 'ytdious--create-entry ytdious-videos))
    (tabulated-list-init-header)
    (tabulated-list-print)
    (ytdious-show-image-asyncron)))

(defun ytdious--query (string n)
  "Query youtube for STRING, return the Nth page of results."
  (let ((videos (ytdious--API-call "search" `(("q" ,string)
					   ("date" ,(symbol-name ytdious-date-criterion))
                                           ("sort_by" ,(symbol-name ytdious-sort-criterion))
					   ("page" ,n)
					   ("fields" ,ytdious-invidious-default-query-fields)))))
    videos))

(defun ytdious-search (query)
  "Search youtube for `QUERY', and redraw the buffer."
  (interactive "sSearch terms: ")
  (setf ytdious-current-page 1)
  (let* ((query-words (split-string query))
	 (terms (seq-group-by (lambda (elem)
				(s-contains-p ":" elem))
			      query-words)))
    (setq-local ytdious-search-term
	  (s-join " " (assoc-default nil terms)))
    (if-let ((date (seq-find
		    (lambda (s) (s-starts-with-p "date:" s) )
		    (assoc-default t terms))))
	(setf ytdious-date-criterion (intern (substring date 5)))
      (setf ytdious-date-criterion 'all)))
  (ytdious--draw-buffer))

(defun ytdious-display-full-title ()
  "Prints full title in minibuffer."
  (interactive)
  (princ (format "\n%s\n" (assoc-default 'title (ytdious-get-current-video)))))

(defun ytdious-rotate-sort (&optional reverse)
  "Rotates through sort criteria.
Optional argument REVERSE reverses the direction of the rotation."
  (interactive)
  (let* ((circle (if reverse 'ring-previous 'ring-next)))
    (setf ytdious-sort-criterion
	  (funcall circle ytdious-sort-options ytdious-sort-criterion)))
  (ytdious--draw-buffer))

(defun ytdious-rotate-sort-backwards ()
  "Rotates through sorting backwards."
  (interactive)
  (ytdious-rotate-sort t))

(defun ytdious-rotate-date (&optional reverse)
  "Rotates through date limit.
Optional argument REVERSE reverses the direction of the rotation."
  (interactive)
  (let* ((circle (if reverse 'ring-previous 'ring-next)))
    (setf ytdious-date-criterion
	  (funcall circle ytdious-date-options ytdious-date-criterion)))
  (ytdious--draw-buffer))

(defun ytdious-rotate-date-backwards ()
  "Rotates through date limit backwards."
  (interactive)
  (ytdious-rotate-date t))

;;;###autoload
(defun ytdious-region-search ()
  "Search youtube for marked region."
  (interactive)
  (let* ((query
	  (buffer-substring-no-properties
	   (region-beginning)
	   (region-end)))
	 (ytdious-search-term query))
    (switch-to-buffer (ytdious-buffer))
    (unless (eq major-mode 'ytdious-mode)
      (ytdious-mode))
    (ytdious-search query)))

(defun ytdious-search-next-page ()
  "Switch to the next page of the current search.  Redraw the buffer."
  (interactive)
  (setf ytdious-current-page (1+ ytdious-current-page))
  (ytdious--draw-buffer))

(defun ytdious-search-previous-page ()
  "Switch to the previous page of the current search.  Redraw the buffer."
  (interactive)
  (when (> ytdious-current-page 1)
    (setf ytdious-current-page (1- ytdious-current-page))
    (ytdious--draw-buffer)))

(defun ytdious-get-current-video ()
  "Get the currently selected video."
  (when (<= (line-number-at-pos) (length ytdious-videos))
    (aref ytdious-videos (1- (line-number-at-pos)))))

(defun ytdious-buffer ()
  "Name for the main ytdious buffer."
  (get-buffer-create "*ytdious*"))

;;;###autoload
(defun ytdious ()
  "Enter ytdious."
  (interactive)
  (switch-to-buffer (ytdious-buffer))
  (unless (eq major-mode 'ytdious-mode)
    (ytdious-mode))
  (call-interactively #'ytdious-search))

(defun ytdious-video-id-fun (video)
  "Return VIDEO id."
  (assoc-default 'videoId video))

(defun ytdious--API-call (method args)
  "Perform a call to the invidious API method METHOD passing ARGS.

Curl is used to perform the request.  An error is thrown if it exits with a non
zero exit code otherwise the request body is parsed by `json-read' and returned."
  (with-temp-buffer
    (let ((exit-code (call-process "curl" nil t nil
				   "--silent"
				   "-X" "GET"
				   (concat ytdious-invidious-api-url
					   "/api/v1/" method
					   "?" (url-build-query-string args)))))
      (unless (= exit-code 0)
	(error "Curl had problems connecting to Invidious"))
      (goto-char (point-min))
      (json-read))))

(provide 'ytdious)

;;; ytdious.el ends here
