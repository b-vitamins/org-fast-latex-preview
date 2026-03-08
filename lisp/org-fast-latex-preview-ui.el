;;; org-fast-latex-preview-ui.el --- Overlay helpers for Org fast previews -*- lexical-binding: t; -*-

;;; Commentary:

;; Overlay placement, deletion, and source-at-point reveal helpers.

;;; Code:

(require 'org-fast-latex-preview-core)
(require 'org-fast-latex-preview-cache)

(defun org-fast-latex-preview--overlay-p (overlay)
  "Return non-nil when OVERLAY is an OFLP preview overlay."
  (overlay-get overlay 'org-fast-latex-preview))

(defun org-fast-latex-preview--find-overlay (beg end)
  "Return the first OFLP overlay spanning BEG and END."
  (when (> org-fast-latex-preview--overlay-count 0)
    (cl-find-if
     (lambda (overlay)
       (and (org-fast-latex-preview--overlay-p overlay)
            (= (overlay-start overlay) beg)
            (= (overlay-end overlay) end)))
     (overlays-in beg end))))

(defun org-fast-latex-preview--overlay-source-current-p (overlay)
  "Return non-nil when OVERLAY still matches buffer contents."
  (let ((source (overlay-get overlay 'org-fast-latex-preview-source)))
    (and source
         (string=
          source
          (buffer-substring-no-properties (overlay-start overlay)
                                          (overlay-end overlay))))))

(defun org-fast-latex-preview--display-spec (file)
  "Return the image display spec for FILE."
  (list 'image :type 'svg :file file :ascent 'center))

(defun org-fast-latex-preview--delete-overlay (overlay)
  "Delete preview OVERLAY if it is still live."
  (when (overlayp overlay)
    (let ((buffer (overlay-buffer overlay)))
      (when (and buffer
                 (org-fast-latex-preview--overlay-p overlay))
        (with-current-buffer buffer
          (setq org-fast-latex-preview--overlay-count
                (max 0 (1- org-fast-latex-preview--overlay-count))))))
    (when (eq overlay org-fast-latex-preview--opened-overlay)
      (setq org-fast-latex-preview--opened-overlay nil))
    (delete-overlay overlay)))

(defun org-fast-latex-preview-clear (&optional beg end)
  "Remove OFLP overlays between BEG and END.

When BEG and END are nil, clear previews from the whole buffer."
  (interactive)
  (if (zerop org-fast-latex-preview--overlay-count)
      nil
    (let ((beg (or beg (point-min)))
          (end (or end (point-max)))
          removed)
      (dolist (overlay (overlays-in beg end))
        (when (org-fast-latex-preview--overlay-p overlay)
          (push overlay removed)
          (org-fast-latex-preview--delete-overlay overlay)))
      removed)))

(defun org-fast-latex-preview--clear-fragment-overlays (fragment)
  "Delete all preview overlays overlapping FRAGMENT."
  (let* ((beg (org-fast-latex-preview--fragment-begin-position fragment))
         (end (org-fast-latex-preview--fragment-end-position fragment)))
    (when (and beg end (> org-fast-latex-preview--overlay-count 0))
      (dolist (overlay (overlays-in beg end))
        (when (org-fast-latex-preview--overlay-p overlay)
          (org-fast-latex-preview--delete-overlay overlay))))))

(defun org-fast-latex-preview--place-overlay (fragment file &optional replace-existing)
  "Place FILE as the preview image for FRAGMENT.

When REPLACE-EXISTING is non-nil, clear any overlapping OFLP overlays
before placing the new preview."
  (let* ((beg (org-fast-latex-preview--fragment-begin-position fragment))
         (end (org-fast-latex-preview--fragment-end-position fragment)))
    (when (and beg end
               (<= beg end)
               (<= end (point-max))
               (string=
                (buffer-substring-no-properties beg end)
                (org-fast-latex-preview--fragment-source fragment)))
      (when replace-existing
        (org-fast-latex-preview--clear-fragment-overlays fragment))
      (let ((overlay (make-overlay beg end)))
        (overlay-put overlay 'org-fast-latex-preview t)
        (overlay-put overlay 'org-overlay-type 'org-latex-overlay)
        (overlay-put overlay 'evaporate t)
        (overlay-put overlay 'help-echo file)
        (overlay-put overlay 'org-fast-latex-preview-source
                     (org-fast-latex-preview--fragment-source fragment))
        (overlay-put overlay 'org-fast-latex-preview-cache-key
                     (org-fast-latex-preview--fragment-cache-key fragment))
        (overlay-put overlay 'org-fast-latex-preview-image file)
        (overlay-put overlay 'org-fast-latex-preview-display
                     (org-fast-latex-preview--display-spec file))
        (overlay-put overlay 'modification-hooks
                     (list
                      (lambda (ov _flag _beg _end &optional _len)
                        (org-fast-latex-preview--delete-overlay ov))))
        (overlay-put overlay 'display
                     (overlay-get overlay 'org-fast-latex-preview-display))
        (cl-incf org-fast-latex-preview--overlay-count)
        overlay))))

(defun org-fast-latex-preview--open-overlay (overlay)
  "Reveal the source text under OVERLAY."
  (when (overlay-buffer overlay)
    (overlay-put overlay 'display nil)))

(defun org-fast-latex-preview--close-overlay (overlay)
  "Restore the preview image for OVERLAY."
  (cond
   ((not (overlay-buffer overlay))
    nil)
   ((not (org-fast-latex-preview--overlay-source-current-p overlay))
    (org-fast-latex-preview--delete-overlay overlay))
   ((org-fast-latex-preview--usable-cache-file-p
     (overlay-get overlay 'org-fast-latex-preview-image))
    (overlay-put overlay 'display
                 (overlay-get overlay 'org-fast-latex-preview-display)))
   (t
    (org-fast-latex-preview--delete-overlay overlay))))

(defun org-fast-latex-preview--at-point-overlay ()
  "Return the preview overlay at point, if any."
  (or (cl-find-if #'org-fast-latex-preview--overlay-p (overlays-at (point)))
      (and (> (point) (point-min))
           (cl-find-if #'org-fast-latex-preview--overlay-p
                       (overlays-at (1- (point)))))))

(provide 'org-fast-latex-preview-ui)
;;; org-fast-latex-preview-ui.el ends here
