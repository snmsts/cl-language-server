;;; slynk-mrepl.lisp
;;
;; Licence: public domain

(defpackage :ls-mrepl
  (:use :cl :ls-api)
  (:export #:create-mrepl
           #:globally-save-object
           #:eval-for-mrepl
           #:sync-package-and-default-directory
           #:pprint-entry
           #:inspect-entry
           #:guess-and-set-package
           #:copy-to-repl
           #:describe-entry
           #:*use-dedicated-output-stream*
           #:*dedicated-output-stream-port*
           #:*dedicated-output-stream-buffering*))
(in-package :ls-mrepl)


;;; MREPL models
(defclass mrepl (channel listener)
  ((remote-id   :initarg  :remote-id :accessor mrepl-remote-id)
   (mode        :initform :eval   :accessor mrepl-mode)
   (tag         :initform nil)
   (pending-errors :initform nil :accessor mrepl-pending-errors))
  (:documentation "A listener implemented in terms of a channel.")
  (:default-initargs
   :initial-env `((cl:*package* . ,(find-package :COMMON-LISP-USER))
                  (*) (**) (***)
                  (/) (//) (///)
                  (+) (++) (+++)
                  (*history* . ,(make-array 40 :fill-pointer 0
                                               :adjustable t)))))

(defmethod print-object ((r mrepl) stream)
  (print-unreadable-object (r stream :type t)
    (format stream "mrepl-~a-~a" (channel-id r) (mrepl-remote-id r))))

(defmethod initialize-instance :before ((r mrepl) &key)
  (setf (slot-value r 'ls-base::in) (make-mrepl-input-stream r)))


;;; Helpers
;;;
(defvar *history* nil)

(defvar *saved-objects* nil)

(defmethod ls-base::drop-unprocessed-events ((r mrepl))
  "Empty REPL of events, then send prompt to Emacs."
  ;; FIXME: Dropping events should be moved to the library, and this
  ;; :DROP nonsense dropped, hence the deliberate SLYNK::.
  (with-slots (mode) r
    (let ((old-mode mode))
      (setf mode :drop)
      (unwind-protect
           (process-requests t)
        (setf mode old-mode)))))

(defun mrepl-get-history-entry (entry-idx)
  (let ((len (length *history*)))
    (assert (and entry-idx
                 (integerp entry-idx)
                 (< -1 entry-idx len))
            nil
            "Illegal history entry ~a for ~a-long history"
            entry-idx
            len)
    (aref *history* entry-idx)))

(defun mrepl-get-object-from-history (entry-idx &optional value-idx)
  (let* ((entry (mrepl-get-history-entry entry-idx))
         (len (length entry)))
    (assert (or (not value-idx)
                (and (integerp value-idx)
                     (< -1 value-idx len)))
            nil
            "History entry ~a is only ~a elements long."
            entry-idx
            len
            value-idx)
    (if (numberp value-idx)
        (nth value-idx entry)
        (values-list entry))))

(defparameter *backreference-character* #\v
  "Character used for #v<entry>:<value> backreferences in the REPL.
Set this to some other value if it conflicts with some other reader
macro that you wish to use in the REPL.
Set this to NIL to turn this feature off.")

(defun backreference-reader (stream subchar arg)
  "Reads #rfoo:bar into (MREPL-GET-OBJECT-FROM-HISTORY foo bar)."
  (declare (ignore subchar arg))
  (let* ((*readtable*
           (let ((table (copy-readtable nil)))
             (set-macro-character #\: (lambda (&rest args) nil) nil table)
             table))
         (entry-idx (progn
                      (when (eq #\: (peek-char nil stream nil nil))
                        (error 'reader-error :stream stream
                               :format-control "~a found in unexpected place in ~a"
                               :format-arguments `(#\: backreference-reader)))
                      (read-preserving-whitespace stream)))
         (value-idx (progn
                      (and (eq #\: (peek-char nil stream nil nil))
                           (read-char stream)
                           (read stream)))))
    `(mrepl-get-object-from-history
      ,entry-idx ,value-idx)))

#+nil
(defun backreference-reader-tests ()
  (let ((expectations
          '(("#v:something" error)
            ("#vnotanumber:something" (notanumber something))
            ("#vnotanumber" (notanumber nil))
            ("#v2 :something" (2 nil) :something)
            ("#v2:99 :something-else" (2 99) :something-else)))
        (*readtable* (let ((table (copy-readtable)))
                       (if *backreference-character*
                           (set-dispatch-macro-character
                            #\#
                            *backreference-character*
                            #'backreference-reader table))
                       table)))
    (loop for (input expected-spec following) in expectations
          collect
          (handler-case 
              (progn
                (with-input-from-string (s input)
                  (let* ((observed (read s))
                         (expected
                           (progn
                             (if (eq 'error expected-spec )
                                 (error "oops, ~a was supposed to have errored, but returned ~a"
                                        input observed))
                             `(mrepl-get-object-from-history ,@expected-spec)))
                         (observed-second (and following
                                               (read s))))
                    
                    
                    (unless (equal observed expected)
                      (error "oops, ~a was supposed to have returned ~a, but returned ~a"
                             input expected observed))
                    (unless (equal observed-second following)
                      (error "oops, ~a was have read ~a after, but read ~a"
                             input following observed-second))
                    (list observed observed-second))))
            (reader-error (e)
              (unless (eq 'error expected-spec)
                (error "oops, ~a wasn't supposed to error with ~a" input e)))))))

(defun make-results (objects)
  (loop for value in objects 
        collect (list (present-for-emacs value #'slynk-pprint)
                      (1- (length *history*)))))

(defun mrepl-eval (repl string)
  (let ((aborted t)
        (results)
        (errored))
    (unwind-protect
         (let* ((previous-hook *debugger-hook*)
                (*debugger-hook* (lambda (condition hook)
                                   ;; ERRORED means we've been through this
                                   ;; handler before in this level of MREPL-EVAL
                                   (unless errored
                                     (push condition (mrepl-pending-errors repl))
                                     (setq aborted condition errored condition)
                                     (with-listener-bindings repl
                                       (send-prompt repl errored)))
                                   (funcall previous-hook condition hook))))
           (setq results (mrepl-eval-1 repl string)
                 ;; If MREPL-EVAL-1 errored once but somehow
                 ;; recovered, set ABORTED to nil
                 aborted nil))
      (unless (eq (mrepl-mode repl) :teardown)
        (flush-listener-streams repl)
        (saving-listener-bindings repl
          (if errored
              (pop (mrepl-pending-errors repl)))
          (cond (aborted
                 (send-to-remote-channel (mrepl-remote-id repl)
                                         `(:evaluation-aborted
                                           ,(ls-base::without-printing-errors
                                                (:object aborted :stream nil)
                                              (prin1-to-string aborted)))))
                (t
                 (when results
                   (setq /// //  // /  / results
                         *** **  ** *  * (car results))
                   (vector-push-extend results *history*))
                 (send-to-remote-channel
                  (mrepl-remote-id repl)
                  `(:write-values ,(make-results results)))))
          (send-prompt repl))))))

(defun prompt-arguments (repl condition)
  `(,(package-name *package*)
    ,(package-string-for-prompt *package*)
    ,(length (mrepl-pending-errors repl))
    ,@(when condition
        (list (write-to-string condition
                               :escape t
                               :readably nil)))))

(defun send-prompt (repl &optional condition)
  (send-to-remote-channel (mrepl-remote-id repl)
                          `(:prompt ,@(prompt-arguments repl condition))))

(defun mrepl-read (repl string)
  (with-slots (tag) repl
    (assert tag)
    (throw tag string)))

(defun mrepl-eval-1 (repl string)
  "In REPL's environment, READ and EVAL forms in STRING."
  (with-sly-interrupts
    ;; Use WITH-LISTENER-BINDINGS (not SAVING-LISTENER-BINDINGS)
    ;; instead, otherwise, if EVAL pops up an error in STRING's form,
    ;; and in the meantime we had some debugging prompts (which make
    ;; recursive calls to this function), the variables *, **, *** and
    ;; *HISTORY* will get incorrectly clobbered to their pre-debugger
    ;; values, whereas we want to serialize this history.
    ;;
    ;; However, as an exception, we /do/ want *PACKAGE* to be
    ;; clobbered if the evaluation of STRING eventually completes.
    ;;
    ;; Another way to see this is: the forms that the user inputs can
    ;; only change the *PACKAGE* binding of the listener's
    ;; environment. Everything else in there is handled automatically.
    ;;
    (with-listener-bindings repl
      (prog1
          (with-retry-restart (:msg "Retry SLY mREPL evaluation request.")
            (with-input-from-string (in string)
              (loop with values
                    for form =
                    (let ((*readtable* (let ((table (copy-readtable)))
                                         (if *backreference-character*
                                             (set-dispatch-macro-character
                                              #\#
                                              *backreference-character*
                                              #'backreference-reader table))
                                         table)))
                      (read in nil in))
                    until (eq form in)
                    do (setq values (multiple-value-list
                                     (eval
                                      (saving-listener-bindings repl
                                        (setq +++ ++ ++ + + form)))))
                    finally
                    (return values))))
        (setf (cdr (assoc '*package* (slot-value repl 'ls-base::env)))
              *package*)))))

(defun set-mode (repl new-mode)
  (with-slots (mode remote-id) repl
    (unless (eq mode new-mode)
      (send-to-remote-channel remote-id `(:set-read-mode ,new-mode)))
    (setf mode new-mode)))

(defun read-input (repl)
  (with-slots (mode tag remote-id) repl
    (flush-listener-streams repl)
    (let ((old-mode mode)
          (old-tag tag))
      (setf tag (cons nil nil))
      (set-mode repl :read)
      (unwind-protect
           (catch tag (process-requests nil))
        (setf tag old-tag)
        (set-mode repl old-mode)))))


;;; Channel methods
;;;
(define-channel-method :inspect-object ((r mrepl) entry-idx value-idx)
  (with-listener-bindings r
    (send-to-remote-channel
       (mrepl-remote-id r)
       `(:inspect-object
         ,(ls-base::inspect-object (mrepl-get-object-from-history entry-idx value-idx))))))

(define-channel-method :process ((c mrepl) string)
  (ecase (mrepl-mode c)
    (:eval (mrepl-eval c string))
    (:read (mrepl-read c string))
    (:drop)))

(define-channel-method :teardown ((r mrepl))
  ;; FIXME: this should be a `:before' spec and closing the channel in
  ;; slynk.lisp's :teardown method should suffice.
  ;;
  (setf (mrepl-mode r) :teardown)
  (call-next-method))

(define-channel-method :clear-repl-history ((r mrepl))
  (saving-listener-bindings r
    ;; FIXME: duplication... use reinitialize-instance
    (setf *history* (make-array 40 :fill-pointer 0
                                   :adjustable t)
          * nil ** nil *** nil
          + nil ++ nil +++ nil
          / nil // nil /// nil)
    (send-to-remote-channel (mrepl-remote-id r) `(:clear-repl-history))
    (send-prompt r)))


;;; slyfuns
;;;
(defslyfun create-mrepl (remote-id)
  (let* ((mrepl (make-instance
                 'mrepl
                 :remote-id remote-id
                 :name (format nil "mrepl-remote-~a" remote-id)
                 :out (make-mrepl-output-stream remote-id))))
    (let ((target (maybe-redirect-global-io *emacs-connection*)))
      (saving-listener-bindings mrepl
        (format *standard-output* "~&; SLY ~a (~a)~%"
                *slynk-wire-protocol-version*
                mrepl)
        (cond ((and target
                    (not (eq mrepl target)))
               (format *standard-output* "~&; Global redirection setup elsewhere~%"))
              ((not target)
               (format *standard-output* "~&; Global redirection not setup~%"))))
      (flush-listener-streams mrepl)
      (send-prompt mrepl)
      (list (channel-id mrepl) (channel-thread-id mrepl)))))

(defslyfun globally-save-object (slave-slyfun &rest args)
  "Apply SLYFUN to ARGS and save the value.
 The saved value should be visible to all threads and retrieved via
 the COPY-TO-REPL slyfun."
  (setq *saved-objects* (multiple-value-list (apply slave-slyfun args)))
  t)

(defmacro with-eval-for-repl ((remote-id &optional mrepl-sym
                                                   update-mrepl) &body body)
  (let ((mrepl-sym (or mrepl-sym
                       (gensym))))
    `(let ((,mrepl-sym (find-channel ,remote-id)))
       (assert ,mrepl-sym)
       (assert
        (eq (ls-backend:thread-id
             (ls-backend:current-thread))
            (channel-thread-id ,mrepl-sym))
        nil
        "This SLYFUN can only be called from threads belonging to MREPL")
       ,(if update-mrepl
            `(saving-listener-bindings ,mrepl-sym
               ,@body)
            `(with-listener-bindings ,mrepl-sym
               ,@body)))))

(defslyfun eval-for-mrepl (remote-id slave-slyfun &rest args)
  "A synchronous form for evaluation in the mREPL context.

Calls SLAVE-SLYFUN with ARGS in the MREPL of REMOTE-ID. Both the
target MREPL's thread and environment are considered.

SLAVE-SLYFUN is typically destructive to the REPL listener's
environment.

This function returns a list of two elements. The first is a list
of arguments as sent in the :PROMPT channel method reply. The second
is the values list returned by SLAVE-SLYFUN transformed into a normal
list."
  (with-eval-for-repl (remote-id mrepl 'allow-destructive)
    (let ((objects (multiple-value-list (apply slave-slyfun args))))
      (list
       (prompt-arguments mrepl nil)
       objects))))

(defslyfun inspect-entry (remote-id entry-idx value-idx)
  (with-eval-for-repl (remote-id)
    (ls-base::inspect-object
     (mrepl-get-object-from-history entry-idx value-idx))))

(defslyfun describe-entry (remote-id entry-idx value-idx)
  (with-eval-for-repl (remote-id)
    (ls-base::describe-to-string
     (mrepl-get-object-from-history entry-idx value-idx))))

(defslyfun pprint-entry (remote-id entry-idx value-idx)
  (with-eval-for-repl (remote-id)
    (ls-base::slynk-pprint
     (list (mrepl-get-object-from-history entry-idx value-idx)))))


;;; "Slave" slyfuns.
;;;
;;; These are slyfuns intented to be called as the SLAVE-SLYFUN
;;; argument of EVAL-FOR-MREPL.
;;;

(defslyfun guess-and-set-package (package-name)
  (let ((package (ls-base::guess-package package-name)))
    (if package
        (setq *package* package)
        (error "Can't find a package for designator ~a" package-name))
    t))

(defslyfun copy-to-repl (&optional entry-idx value-idx)
  "Recall objects in *HISTORY* or *SAVED-OBJECTS* as the last entry."
  (let ((objects
          (cond ((and entry-idx value-idx)
                 (list (mrepl-get-object-from-history entry-idx value-idx)))
                (entry-idx
                 (mrepl-get-history-entry entry-idx))
                (value-idx
                 (error "Doesn't make sense"))
                (t
                 *saved-objects*))))
    (setq /// //  // /  / objects
          *** **  ** *  * (car objects))
    (vector-push-extend objects *history*)
    (values-list (make-results objects))))

(defslyfun sync-package-and-default-directory (&key package-name directory)
  (when directory
    (ls-base:set-default-directory directory))
  (when package-name
    (guess-and-set-package package-name))
  (values (package-name *package*) (ls-backend:default-directory)))


;;;; Dedicated stream
;;;;
(defparameter *use-dedicated-output-stream* t
  "When T, dedicate a second stream for sending output to Emacs.")

(defparameter *dedicated-output-stream-port* 0
  "Which port we should use for the dedicated output stream.")

(defparameter *dedicated-output-stream-buffering*
  (if (eq ls-base:*communication-style* :spawn) :line nil)
  "The buffering scheme that should be used for the output stream.
Be advised that some Lisp backends don't support this.
Valid values are nil, t, :line.")

(defun make-mrepl-output-stream (remote-id)
  (or (and *use-dedicated-output-stream*
           (open-dedicated-output-stream remote-id))
      (ls-backend:make-output-stream
       (make-thread-bindings-aware-lambda
        (lambda (string)
          (send-to-remote-channel remote-id `(:write-string ,string)))))))

(defun make-mrepl-input-stream (repl)
  (ls-backend:make-input-stream
   (lambda () (read-input repl))))

(defun open-dedicated-output-stream (remote-id)
  "Establish a dedicated output connection to Emacs.

Emacs's channel at REMOTE-ID is notified of a socket listening at an
ephemeral port. Upon connection, the listening socket is closed, and
the resulting connecion socket is used as optimized way for Lisp to
deliver output to Emacs."
  (let ((socket (ls-backend:create-socket ls-base::*loopback-interface*
                                             *dedicated-output-stream-port*))
        (ef (or (some #'ls-base::find-external-format '("utf-8-unix" "utf-8"))
                (error "no suitable coding system for dedicated stream"))))
    (unwind-protect
         (let ((port (ls-backend:local-port socket)))
           (send-to-remote-channel remote-id
                                   `(:open-dedicated-output-stream ,port nil))
           (let ((dedicated (ls-backend:accept-connection
                             socket
                             :external-format ef
                             :buffering *dedicated-output-stream-buffering*
                             :timeout 30)))
             (ls-base:authenticate-client dedicated)
             (ls-backend:close-socket socket)
             (setf socket nil)
             ;; See github issue #21: Only sbcl and cmucl apparently
             ;; respect :LINE as a buffering type, hence this reader
             ;; conditional. This could/should be a definterface, but
             ;; looks harmless enough...
             ;;
             #+(or sbcl cmucl)
             dedicated
             ;; ...on other implementations we make a relaying gray
             ;; stream that is guaranteed to use line buffering for
             ;; WRITE-SEQUENCE. That stream writes to the dedicated
             ;; socket whenever it sees fit.
             ;;
             #-(or sbcl cmucl)
             (if (eq *dedicated-output-stream-buffering* :line)
                 (ls-backend:make-output-stream
                  (lambda (string)
                    (write-sequence string dedicated)
                    (force-output dedicated)))
                 dedicated)))
      (when socket
        (ls-backend:close-socket socket)))))


;;;; Globally redirect IO to Emacs
;;;
;;; This code handles redirection of the standard I/O streams
;;; (`*standard-output*', etc) into Emacs. If any LISTENER objects
;;; exist in the CONNECTION structure, they will contain the
;;; appropriate streams, so all we have to do is make the right
;;; bindings.
;;;
;;; When the first ever MREPL is created we redirect the streams into
;;; it, and they keep going into that MREPL even if more are
;;; established, in the current connection or even other
;;; connections. If the MREPL is closed (interactively or by closing
;;; the connection), we choose some other MREPL (in some other default
;;; connection possibly), or, or if there are no MREPL's left, we
;;; revert to the original (real) streams.
;;;
;;; It is slightly tricky to assign the global values of standard
;;; streams because they are often shadowed by dynamic bindings. We
;;; solve this problem by introducing an extra indirection via synonym
;;; streams, so that *STANDARD-INPUT* is a synonym stream to
;;; *CURRENT-STANDARD-INPUT*, etc. We never shadow the "current"
;;; variables, so they can always be assigned to affect a global
;;; change.
(defparameter *globally-redirect-io* t
  "When non-nil globally redirect all standard streams to Emacs.")

(defvar *saved-global-streams* '()
  "A plist to save and restore redirected stream objects.
E.g. the value for '*standard-output* holds the stream object
for *standard-output* before we install our redirection.")

(defvar *standard-output-streams*
  '(*standard-output* *error-output* *trace-output*)
  "The symbols naming standard output streams.")

(defvar *standard-input-streams*
  '(*standard-input*)
  "The symbols naming standard input streams.")

(defvar *standard-io-streams*
  '(*debug-io* *query-io* *terminal-io*)
  "The symbols naming standard io streams.")

(defvar *target-listener-for-redirection* nil
  "The listener to which standard I/O streams are globally redirected.
NIL if streams are not globally redirected.")

(defun setup-stream-indirection (stream-var &optional stream)
  "Setup redirection scaffolding for a global stream variable.
Supposing (for example) STREAM-VAR is *STANDARD-INPUT*, this macro:

1. Saves the value of *STANDARD-INPUT* in `*SAVED-GLOBAL-STREAMS*'.

2. Creates *CURRENT-STANDARD-INPUT*, initially with the same value as
*STANDARD-INPUT*.

3. Assigns *STANDARD-INPUT* to a synonym stream pointing to
*CURRENT-STANDARD-INPUT*.

This has the effect of making *CURRENT-STANDARD-INPUT* contain the
effective global value for *STANDARD-INPUT*. This way we can assign
the effective global value even when *STANDARD-INPUT* is shadowed by a
dynamic binding."
  (let ((current-stream-var (prefixed-var '#:current stream-var))
        (stream (or stream (symbol-value stream-var))))
    ;; Save the real stream value for the future.
    (setf (getf *saved-global-streams* stream-var) stream)
    ;; Define a new variable for the effective stream.
    ;; This can be reassigned.
    (proclaim `(special ,current-stream-var))
    (set current-stream-var stream)
    ;; Assign the real binding as a synonym for the current one.
    (let ((stream (make-synonym-stream current-stream-var)))
      (set stream-var stream)
      (ls-base::set-default-initial-binding stream-var `(quote ,stream)))))

(defun prefixed-var (prefix variable-symbol)
  "(PREFIXED-VAR \"FOO\" '*BAR*) => SLYNK::*FOO-BAR*"
  (let ((basename (subseq (symbol-name variable-symbol) 1)))
    (intern (format nil "*~A-~A" (string prefix) basename) :slynk)))

(defun init-global-stream-redirection ()
  (cond (*saved-global-streams*
         (warn "Streams already redirected."))
        (t
         (mapc #'setup-stream-indirection
               (append *standard-output-streams*
                       *standard-input-streams*
                       *standard-io-streams*)))))

(defun globally-redirect-to-listener (listener)
  "Set the standard I/O streams to redirect to LISTENER.
Assigns *CURRENT-<STREAM>* for all standard streams."
  (saving-listener-bindings listener
    (dolist (o *standard-output-streams*)
      (set (prefixed-var '#:current o)
           *standard-output*))

    ;; FIXME: If we redirect standard input to Emacs then we get the
    ;; regular Lisp top-level trying to read from our REPL.
    ;;
    ;; Perhaps the ideal would be for the real top-level to run in a
    ;; thread with local bindings for all the standard streams. Failing
    ;; that we probably would like to inhibit it from reading while
    ;; Emacs is connected.
    ;;
    ;; Meanwhile we just leave *standard-input* alone.
    #+NIL
    (dolist (i *standard-input-streams*)
      (set (prefixed-var '#:current i)
           (connection.user-input connection)))
    (dolist (io *standard-io-streams*)
      (set (prefixed-var '#:current io)
           *terminal-io*))))

(defun revert-global-io-redirection ()
  "Set *CURRENT-<STREAM>* to *REAL-<STREAM>* for all standard streams."
  ;; Log to SLYNK:*LOG-OUTPUT* since the standard streams whose
  ;; redirection are about to be reverted might be in an unconsistent
  ;; state after, for instance, restarting an image.
  ;;
  (format ls-base:*log-output* "~&; About to revert global IO direction~%")
  (when *target-listener-for-redirection*
    (flush-listener-streams *target-listener-for-redirection*))
  (dolist (stream-var (append *standard-output-streams*
                              *standard-input-streams*
                              *standard-io-streams*))
    (set (prefixed-var '#:current stream-var)
         (getf *saved-global-streams* stream-var))))

(defun maybe-redirect-global-io (connection)
  "Consider globally redirecting output to CONNECTION's listener.

Return the current redirection target, or nil"
  (let ((l (default-listener connection)))
    (when (and *globally-redirect-io*
               (null *target-listener-for-redirection*)
               l)
      (unless *saved-global-streams*
        (init-global-stream-redirection))
      (setq *target-listener-for-redirection* l)
      (globally-redirect-to-listener l)
      (with-listener-bindings l
        (format *standard-output* "~&; Redirecting all output to this MREPL~%")
        (flush-listener-streams l)))
    *target-listener-for-redirection*))

(defmethod close-channel :before ((r mrepl))
  ;; If this channel was the redirection target.
  (close-listener r)
  (when (eq r *target-listener-for-redirection*)
    (setq *target-listener-for-redirection* nil)
    (maybe-redirect-global-io (default-connection))
    (unless *target-listener-for-redirection*
      (revert-global-io-redirection)
      (format *standard-output* "~&; Reverted global IO direction~%"))))

(provide :ls-mrepl)
