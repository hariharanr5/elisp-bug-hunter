;;; bug-hunter.el --- Hunt down errors in elisp files  -*- lexical-binding: t; -*-

;; Copyright (C) 2015 Free Software Foundation, Inc.

;; Author: Artur Malabarba <bruce.connor.am@gmail.com>
;; URL: http://github.com/Bruce-Connor/elisp-bug-hunter
;; Version: 0.1
;; Keywords: lisp
;; Package-Requires: ((seq "1.3"))

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
;; `bug-hunter' is an Emacs library that finds the source of a bug inside
;; any given `.el' file.
;;
;;
;; Usage Examples
;; ==============
;;
;;   1. If your Emacs init file signals an error during startup, but you
;;      don’t know why, simply issue
;;      ,----
;;      | M-x bug-hunter-init-file RET RET
;;      `----
;;      and `bug-hunter' will find it for you.
;;
;;   2. If Emacs starts up without errors but something is not working as
;;      it should, invoke the same command, but give it in an assertion:
;;      ,----
;;      | M-x bug-hunter-init-file RET (when issue-detected t) RET
;;      `----
;;
;;   3. You can also use `bug-hunter-file' to hunt in other files, or even
;;      `bug-hunter-hunt' to search in a list of expressions.
;;
;;
;; Installation
;; ============
;;
;;   It is part of Emacs and is available trough GNU Elpa. To install,
;;   issue
;;
;;   ,----
;;   | M-x package-install RET bug-hunter
;;   `----


;;; Code:
(require 'seq)

(defun bug-hunter--read-buffer ()
  "Return all sexps after point as a list."
  (let ((out))
    (ignore-errors
      (while t
        (push (read (current-buffer)) out)))
    (nreverse out)))

(defun bug-hunter--read-contents (file)
  "Return all sexps in FILE as a list."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (bug-hunter--read-buffer)))

(defun bug-hunter--report-print (&rest r)
  (with-current-buffer (get-buffer-create "*Bug-Hunter Report*")
    (goto-char (point-max))
    (let ((inhibit-read-only t))
      (insert "\n" (apply #'format r)))))

(defun bug-hunter--report (&rest r)
  (declare (indent 1))
  (apply #'bug-hunter--report-print r)
  (apply #'message r))

(defun bug-hunter--report-end (&rest r)
  (declare (indent 1))
  (apply #'bug-hunter--report-print r)
  (bug-hunter--report-print "")
  (apply #'user-error r))

(defun bug-hunter--run-form (form)
  "Run FUNCTION with \"emacs -Q\" and return the result."
  (let ((out-buf (generate-new-buffer "*Bug-Hunter Command*"))
        (exec (file-truename (expand-file-name invocation-name
                                               invocation-directory)))
        (file-name (make-temp-file "bug-hunter")))
    (unwind-protect
        (progn
          (with-temp-file file-name
            (let ((print-length nil)
                  (print-level nil))
              (print (list 'prin1 form) (current-buffer)))
            (buffer-string))
          (shell-command
           (concat (shell-quote-argument exec)
                   " -Q --batch -l "
                   (shell-quote-argument file-name))
           out-buf))
      (delete-file file-name))
    (with-current-buffer out-buf
      (goto-char (point-max))
      (forward-sexp -1)
      (prog1 (read (current-buffer))
        (kill-buffer (current-buffer))))))

(defun bug-hunter--run-and-test (forms assertion)
  "Execute FORMS in the background and test ASSERTION.
See `bug-hunter' for a description on the ASSERTION."
  (bug-hunter--run-form
   `(condition-case er
        (progn ,@forms
               (run-hooks 'after-init-hook)
               ,assertion)
      (error (cons 'error er)))))

(defun bug-hunter--init-report-buffer ()
  (or (get-buffer "*Bug-Hunter Report*")
      (with-current-buffer (get-buffer-create "*Bug-Hunter Report*")
        (special-mode)
        (current-buffer))))


;;; The actual bisection
(defun bug-hunter--split (l)
  (seq-partition l (ceiling (/ (length l) 2.0))))

(defvar bug-hunter--i 0)
(defvar bug-hunter--estimate 0)

(defun bug-hunter--bisect (assertion safe head &optional tail)
  "Implementation used by `bug-hunter--bisect-start'."
  (cond
   ((not tail)
    (vector (length safe)
            ;; Sometimes we already ran this, sometimes not. So it's
            ;; easier to just run it anyway to get the return value.
            (bug-hunter--run-and-test (append safe head) assertion)))
   ((and (message "Testing: %s/%s"
           (setq bug-hunter--i (1+ bug-hunter--i))
           bug-hunter--estimate)
         (bug-hunter--run-and-test (append safe head) assertion))
    (apply #'bug-hunter--bisect
      assertion
      safe
      (bug-hunter--split head)))
   (t (apply #'bug-hunter--bisect
        assertion
        (append safe head)
        (bug-hunter--split tail)))))

(defun bug-hunter--bisect-start (forms assertion)
  "Run a bisection search on list of FORMS using ASSERTION.
Returns a vector [n value], where n is the position of the first
element in FORMS which trigger ASSERTION, and value is the
ASSERTION's return value.

If ASSERTION is nil, n is the position of the first form to
signal an error and value is (error . ERROR-SIGNALED)."
  (let ((bug-hunter--i 0)
        (bug-hunter--estimate (ceiling (log (length forms) 2))))
    (apply #'bug-hunter--bisect assertion nil (bug-hunter--split forms))))


;;; Main functions
(defun bug-hunter-hunt (forms assertion)
  "Bisect FORMS using ASSERTION.
FORMS is a list of elisp expressions which are either throwing an
error or causing some undesirable effect.

ASSERTION is either nil or an expression.

If it is nil, FORMS are bisected until they stop throwing errors.
If it is an expression, FORMS are bisected by testing ASSERTION.
It should return nil if all is fine (e.g. if used with \"emacs -Q\"),
and should return non-nil when a problem is detected.

Make sure that ASSERTION does not throw errors when all is
well (check against emacs -Q).
One common source of that is to rely on a feature being loaded."
  (pop-to-buffer (bug-hunter--init-report-buffer))
  (bug-hunter--report "Testing assertion...")
  (unless (bug-hunter--run-and-test forms assertion)
    (bug-hunter--report-end "Test failed.\n%s\n%s"
      (if assertion "Assertion returned nil even with all forms evaluated:"
        "No errors signaled even with all forms evaluated")
      (or assertion "")))
  (when (bug-hunter--run-and-test nil assertion)
    (bug-hunter--report-end "Test failed.\n%s\n%s"
      (if assertion "Assertion returned non-nil even on emacs -Q:"
        "Signaled an error even on emacs -Q")
      (or assertion "")))
  (bug-hunter--report "Initial tests done. Hunting for the cause...")
  (let* ((result (bug-hunter--bisect-start forms assertion)))
    (if (not result)
        (bug-hunter--report-end "No problem was found, despite our initial tests.\n%s"
          "I have no idea what's going on.")
      (let ((pos (elt result 0))
            (ret (elt result 1)))
        (bug-hunter--report "Bug encountered on the following sexp at position %s:\n    %S"
          pos
          (elt forms pos))
        (if (eq (car-safe ret) 'error)
            (bug-hunter--report "The following error was signaled: %s\n" (cdr ret))
          (bug-hunter--report "The return value was: %s\n" ret))
        result))))

;;;###autoload
(defun bug-hunter-file (file &optional assertion)
  "Test ASSERTION while bisecting FILE.
All sexps in FILE are read and passed to `bug-hunter-hunt' as a
list.  See `bug-hunter-hunt' for how to use assertion."
  (interactive
   (list
    (read-file-name "File to bisect: "
                    (file-name-directory (or (buffer-file-name) "./"))
                    nil t
                    (file-name-nondirectory (or (buffer-file-name) "./")))
    (cons #'progn
          (with-temp-buffer
            (insert
             (read-string "Expression that returns non-nil if there's a problem: "
                          nil 'read-expression-history))
            (goto-char (point-min))
            (bug-hunter--read-buffer)))))
  (bug-hunter-hunt (bug-hunter--read-contents file) assertion))

;;;###autoload
(defun bug-hunter-init-file (&optional assertion)
  "Test ASSERTION throughout `user-init-file'.
All sexps inside `user-init-file' are read and passed to
`bug-hunter-hunt' as a list.  See `bug-hunter-hunt' for how to use
assertion."
  (interactive
   (list
    (cons #'progn
          (with-temp-buffer
            (insert
             (read-string "Expression that returns non-nil if there's a problem: "
                          nil 'read-expression-history))
            (goto-char (point-min))
            (bug-hunter--read-buffer)))))
  (bug-hunter-file user-init-file assertion))

(provide 'bug-hunter)
;;; bug-hunter.el ends here
