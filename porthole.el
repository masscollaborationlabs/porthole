(require 'cl-lib)
(require 'elnode)
(require 'json-rpc-server)
(require 'f)


;; We have to monkeypatch Elnode before using it on Emacs 26, possibly other
;; Emacs too.
(require 'porthole-elnode-monkeypatch)


;;; Code


(defvar porthole--running-servers '()
  "Alist of running HTTP-RPC servers.

Maps server names (strings) to their respective `porthole--server'
objects.")


(cl-defstruct porthole--server
  "Structure representing an HTTP RPC server.

This struct is intended to be used as a record of the running RPC
server."
  (name :read-only t :type string)
  (port :read-only t)
  (exposed-functions '())
  (username nil :read-only t)
  (password nil :read-only t)
  (elnode-process :read-only t)
  )


(define-error 'porthole-400-error "The HTTP request was not valid")
(define-error 'porthole-malformed-http-request
  "The request was malformed"
  'porthole-400-error)
(define-error 'porthole-invalid-http-request
  "The request was invalid"
  'porthole-400-error)
(define-error 'porthole-401-error
  "Authentication required")


(defun porthole-xor (arg1 arg2)
  "Exclusive or of two parameters, `ARG1' and `ARG2'.

This is not a bitwise comparison. It uses the truthiness of the
arguments to evaluate the result."
  (and (or arg1 arg2)
       (not (and arg1 arg2))))


(defun porthole--case-insensitive-comparison (string1 string2)
  "Check if two objects are identical strings, case insensitive.

Tolerates non-string input. Will simply return nil if a
non-string is supplied."
  (and (stringp string1) (stringp string2)
       (string= (downcase string1) (downcase string2))))


(defun porthole--similar-keys (key1 key2)
  "Are two keys the same at a fundamental level?

This is a utility function for `porthole-alist-get'. It compares
keys. Symbol keys can match string keys, and all keys are
compared case-insensitively.

See `htpc-alist-get' for usage examples."
  ;; Convert symbols to strings before comparison
  (unless (stringp key1)
    (setq key1 (format "%s" key1)))
  (unless (stringp key2)
    (setq key2 (format "%s" key2)))
  ;; Compare the two strings
  (porthole--case-insensitive-comparison key1 key2))


(defun porthole-alist-get (key alist)
  "Like `alist-get', but much more flexible.

`KEY' is the key to query.
`ALIST' is the alist to search.

Will match symbols against strings. Will also match strings
case-insensitively.

For example:

  - The symbol 'key will match the string \"key\"

  - The string \"key\" match the string \"Key\"

  - The symbol 'key will match the string \"KEY\"

  - The symbol 'key will match the symbol 'KEY

  - The symbol 'key will NOT match the symbol 'keys"
  (let ((pair (assoc key alist 'porthole--similar-keys)))
    (and pair
         (eq (type-of pair) 'cons)
         (cdr pair))))


(defun porthole--alist-remove (key alist)
  "Remove all pairs referenced by `KEY' in `ALIST'.

Returns a new alist without those elements."
  (cl-delete server-name porthole--running-servers :key #'car :test #'equal))


(defun porthole--random-sha256-key ()
  ;; Make 400 random strings, join them, then hash the result. That should be
  ;; suitably unique.
  (let ((long-random-number
         (apply 'concat (mapcar (lambda (_)
                                  (format "%s" (random 9999999999999)))
                                (number-sequence 0 400)))))
    (secure-hash 'sha256 long-random-number)))


(defun porthole--send-400 (httpcon message)
  (elnode-send-400 httpcon message))


(defun porthole--extract-content (httpcon)
  "Extract the body of an HTTP request.

Ordinarily, Elnode provides no method to extract the raw content
from an HTTP request. This is an extension function to allow
this.

This is ripped from `elnode--http-post-to-alist', extracted into
its own function to enable custom body handling."
  (with-current-buffer (process-buffer httpcon)
    (buffer-substring
     ;; we might have to add 2 to this because of trailing \r\n
     (process-get httpcon :elnode-header-end)
     (point-max))))


(defun porthole--assert-authenticated (headers porthole-server)
  "Ensure a request had valid authentication.

If not, a relevant `porthole-' error will be raised that can be used
to construct a response.

`HEADERS' should be an alist of the headers, extracted from the
`elnode' httpcon object."
  (let ((target-username (porthole--server-username porthole-server))
        (target-password (porthole--server-password porthole-server)))
    ;; Only perform authentication when a username or password are required.
    ;; Otherwise, it's authenticated by default.
    (when (or target-username target-password)
      (let ((authorization (porthole-alist-get "Authorization" headers)))
        (unless authorization
          (signal 'porthole-401-error "authentication required"))
        ;; The code below that actually parses the authorization header is
        ;; ripped from `web-server.el' by Eric Schulte. See the method
        ;; `ws-parse' for more information.
        (string-match "\\([^[:space:]]+\\) \\(.*\\)$" authorization)
        (let ((protocol (match-string 1 authorization))
              (credentials (match-string 2 authorization)))
          (unless protocol
            (signal 'porthole-malformed-http-request "Invalid authorization string"))
          (unless credentials
            (signal 'porthole-malformed-http-request "No credentials provided"))
          (unless (porthole--case-insensitive-comparison
                   protocol "basic")
            ;; If they've supplied the wrong protocol, just tell them
            ;; authentication is required.
            (signal 'porthole-401-error "authentication required"))
          (let ((decoded-credentials (base64-decode-string credentials)))
            ;; Cover the case where we match at position 0.
            (if (integerp (string-match ":" decoded-credentials))
                (let ((provided-username (substring decoded-credentials 0
                                                    (match-beginning 0)))
                      (provided-password (substring decoded-credentials
                                                    (match-end 0))))
                  (unless (and (equal provided-username target-username)
                               (equal provided-password target-password))
                    (signal 'porthole-401-error "invalid credentials")))
              (signal 'porthole-malformed-request
                      (format "bad credentials: \"%s\""
                              decoded-credentials)))))))))


(defun porthole--server-from-port (port)
  "Get the `porthole--server' object running on `PORT'.

Throws an error if no server could be found running on that
port."
  (catch 'server-found
    ;; Check port against each running server
    (mapc (lambda (server-pair)
            (let* ((server (cdr server-pair))
                   (server-port (porthole--server-port server)))
              (when (eq port server-port)
                ;; Server matches! Return it.
                (throw 'server-found server))))
          porthole--running-servers)
    ;; No server was found. Raise an error.
    (error "%s" (format "No `porthole--server' could be found running on port %s"
                        port))))


(defun porthole--server-from-httpcon (httpcon)
  "Get the `porthole--server' that this `HTTPCON' is connecting to.

Returns an `porthole--server' object.

Throws an error if no object could be found."
  ;; We get the underlying Elnode server that's serving the connection, then we
  ;; get the `porthole--server' from that.
  ;;
  ;; We use the port as the key to extract the `porthole--server'. Why introduce the
  ;; extra step? Why not use the Elnode server as the key? Well, ports are
  ;; probably more robust. What if Elnode restarted its server for some reason,
  ;; such as rebooting after a fatal error? The ports should still match, even
  ;; if the servers don't.
  (or (porthole--server-from-port
       (let ((underlying-elnode-server (process-get httpcon :server)))
         (process-contact underlying-elnode-server :service)))
      ;; Block if no server found.
      (error "%s" "No `porthole--server' could be found for `HTTPCON'")))


(defun porthole--handle-request (httpcon)
  "Handle a JSON-RPC request.

This method extracts the underlying JSON-RPC request and passes
it to the RPC layer to be executed. It then responds to the
client with the result."
  (condition-case err
      (let ((headers (elnode-http-headers httpcon))
            (porthole-server (porthole--server-from-httpcon httpcon)))
        ;; Authenticate first
        (porthole--assert-authenticated headers porthole-server)
        (let ((content-type (porthole-alist-get "Content-Type" headers)))
          (unless content-type
            (signal 'porthole-invalid-http-request
                    (format "No `Content-Type` provided.")))
          (unless (porthole--case-insensitive-comparison
                   (format "%s" content-type)
                   "application/json")
            (signal 'porthole-invalid-http-request
                    (format
                     "`Content-Type` should be application/json. Was: %s"
                     content-type)))
          (let ((content (porthole--extract-content httpcon)))
            (unless content
              (signal 'porthole-invalid-http-request
                      "Content could not be extracted from the request."))
            (let* ((exposed-functions (porthole--server-exposed-functions porthole-server))
                   (porthole-response (jrpc-handle content exposed-functions)))
              (elnode-http-start httpcon 200 '("Content-Type" . "application/json"))
              (elnode-http-return httpcon porthole-response)))))
    (porthole-401-error
     (porthole--send-401 httpcon (cdr err)))
    (porthole-400-error
     (porthole--send-400 httpcon (cdr err)))
    (error
     (elnode-send-500 httpcon (format "An internal error occurred. Error: %s"
                                      err)))))


(defun porthole--send-401 (httpcon &optional message)
  (elnode-http-start httpcon 401
                     '("WWW-Authenticate" . "Basic realm=\"emacs-rpc-server\"")
                     '("Content-Type" . text/html))
  (elnode-http-return httpcon (or message
                                  "authentication required")))


(defun porthole--server-port (elnode-server-instance)
  "Get the actual port an `elnode-server' is running on.

By default, `ws-server' objects store the port which was given as
input to create the server. This may not actually be the port the
server is running on. For example, if a server was created with
dynamic port allocation, the `ws-server' object may have the port
stored as \"0\" or t - even though the network process was
allocated a specific port.

This method bypasses the flawed `ws-server' implementation and
extract the actual port from the underlying network process."
  ;; (process-contact (oref ws-server-instance process) :service)
  (warn "Port getting not implemented"))


(defun porthole--on-linux ()
  "Is this instance of Emacs running on Linux?"
  (eq system-type 'gnu/linux))


(defun porthole--on-windows ()
  "Is this instance of Emacs running on Windows?"
  (eq (system-type 'windows-nt)))


(defun porthole--on-mac ()
  "Is this instance of Emacs running on MacOS?"
  (eq (system-type 'darwin)))


(defun porthole--get-linux-temp-dir ()
  "Get a user-only temp dir on Linux, to store the server info in."
  ;; If the runtime dir isn't available, fall back to the home dir.
  (or (getenv "XDG_RUNTIME_DIR")
      (let ((home (getenv "HOME")))
        (if home
            (progn
              (display-warning
               "porthole"
               (concat "$XDG_RUNTIME_DIR environment variable not set. Using "
                       "$HOME/tmp as the base temp directory instead."))
              (f-join home "/tmp"))
          (display-warning
           "porthole"
           (concat "Neither $XDG_RUNTIME_DIR nor $HOME could be read from "
                   "the environment. Clients will not be able to automatically "
                   "connect to the server by reading the temp file."))))))


(defconst porthole--base-temp-dir
  (cond ((porthole--on-linux)
         (porthole--get-linux-temp-dir))
        ((porthole--on-windows
          (getenv "TEMP")))
        ((porthole--on-mac)
         ;; TODO: Mac temp dir
         (error "Not Implemented on Mac yet"))
        (t
         (display-warning
          "porthole"
          (concat "Unrecognised system type. Don't know where to find the "
                  "temp directory. Clients will not be able to automatically "
                  "read the RPC server's configuration"))))
  "The base temp directory to use.

This will be dependent on the current system.")


(defconst porthole--session-info-dir
  (when porthole--base-temp-dir
    (f-join porthole--base-temp-dir "emacs-porthole"))
  "Directory in which to store files relating to the current server session.

This is a known name, so clients can also read it and gather
relevant information.")


(defconst porthole--session-file-name "session.json"
  "Local filename for a session info file.

"
  ;; TODO: Flesh out session file name docstring
  )


;; (defun porthole--publish-port (port)
;;   "Write the server's port number to a temporary file.

;; This file is used so clients can determine which port the server
;; was dynamically allocated at creation. It is not necessary if a
;; fixed port was used, but it can still be useful to reduce setup."
;;   (if porthole--port-number-temp-file
;;       (progn
;;         ;; Make at least some effort to clean up the port file when Emacs is closed.
;;         ;; This will only clean it up when `kill-emacs' is called, but it's better
;;         ;; than nothing.
;;         (add-hook 'kill-emacs-hook 'porthole--erase-port-file)
;;         (unwind-protect
;;             (progn
;;               (find-file porthole--port-number-temp-file)
;;               ;; Erase any existing port information.
;;               (erase-buffer)
;;               (insert (format "%s" port))
;;               ;; Create the rpc server's subdir if it doesn't exist in the temp
;;               ;; folder.
;;               (unless (file-directory-p porthole--session-info-dir)
;;                 (make-directory porthole--session-info-dir))
;;               ;; Possible race condition here if the temp dir is cleaned up
;;               ;; between these two operations. Very small chance though, and all
;;               ;; that will happen is the user will be prompted to confirm the
;;               ;; directory creation.
;;               (write-file porthole--port-number-temp-file nil)
;;               (message
;;                (concat
;;                 "JSON-RPC server port written to \"%s\". This file can "
;;                 "be used by clients to determine the port to connect to.")
;;                porthole--port-number-temp-file))
;;           (kill-current-buffer)))
;;     (display-warning
;;      "porthole"
;;      "The server's session information will not be published.")))


(defun porthole--find-free-port (host)
  "Get a dynamically allocated port. This port should be free.

Note that using this method will probably produce a small chance
of a race condition. The port could theoretically be claimed
between this method returning and another method trying to use
the port. The chance of this happening is small, but it should
still be protected against."
  (let* ((free-port-process (make-network-process
                             :name "*porthole-free-port-finding-service*"
                             :host host
                             :service 0
                             :server t
                             :family 'ipv4))
         (port (process-contact free-port-process :service)))
    (delete-process free-port-process)
    port))


;; (defun porthole--erase-port-file ()
;;   "Erase the port information file, if it exists."
;;   (if (file-exists-p porthole--port-number-temp-file)
;;       (delete-file porthole--port-number-temp-file nil)))


(defun porthole--get-session-folder (server-name)
  "Get the session info folder for `SERVER-NAME'."
  ;; Session file should be at:
  ;; <porthole-info-dir>/<server-name>/session.json
  (f-join porthole--session-info-dir server-name))


(defun porthole-get-session-file-path (server-name)
  "Get the path of the session file for server with name `SERVER-NAME'."
  ;; Session file should be at:
  ;; <porthole-info-dir>/<server-name>/session.json
  (f-join (porthole--get-session-folder server-name)
          porthole--session-file-name))


(cl-defun porthole--publish-session-file (name
                                      port
                                      username
                                      password
                                      &key
                                      (publish-port t)
                                      (publish-username t)
                                      (publish-password t))
  "Publish the current session's session info."
  ;; TODO: Flesh out docstring.
  (let ((info '()))
    (when publish-port
      (push `(port . ,port)
            info))
    (when publish-username
      (push `(username . ,username)
            info))
    (when publish-password
      (push `(password . ,password)
            info))
    (let ((info-as-json (json-encode info))
          (info-folder (porthole--get-session-folder name))
          (info-filename (porthole-get-session-file-path name)))
      (unless (f-dir-p info-folder)
        ;; Make the app and server directories, if they don't exist.
        (make-directory info-folder t))
      (with-temp-file info-filename
        (insert info-as-json)))))


(defun porthole--erase-session-file (server-name)
  "Delete the server's session file.

Also deletes the server's session folder."
  (let ((info-folder (porthole--get-session-folder server-name))
        (info-filename (porthole-get-session-file-path server-name)))
    (when (f-file-p info-filename)
      (f-delete info-filename))
    (when (f-dir-p info-folder)
      (f-delete info-folder t))))


(defun porthole--running-server-names ()
  "Get the names of all running servers."
  (mapcar 'car porthole--running-servers))


(defun porthole--get-server (server-name)
  "Get the `porthole--server' with name `SERVER-NAME'.

Returns nil if no server with this name is running."
  (porthole-alist-get server-name porthole--running-servers))


(defun porthole--server-running-p (server-name)
  "Returns t if a server with `SERVER-NAME' is already running.

Note that server names are case-insensitive."
  (if (porthole--get-server server-name) t nil))


(defun porthole--assert-server-running (server-name &optional message)
  "Ensure a server is running. If not, throw an error.

`SERVER-NAME' is the name of the server to check"
  (unless (porthole--server-running-p server-name)
    (error "%s" (or message
                    (format "No server named \"%s\" is running" server-name)))))


(defun porthole--assert-server-not-running (server-name &optional message)
  "If a server with `SERVER-NAME' is running, throw an error.

`SERVER-NAME' is the name of the server to check."
  (when (porthole--server-running-p server-name)
    (error "%s" (or message
                    (format "A server with the name \"%s\" is already running"
                            server-name)))))


(cl-defun porthole-start-server (name &key (exposed-functions '()))
  "Start a server. `NAME' should be the name of the server.

`NAME' should be a string that references the server. It should
be a unique name. Only alphanumeric characters and dashes are
allowed.

`EXPOSED-FUNCTIONS' is optional. If provided, these functions
will immediately be available to call from the server when it is
launched.

This is the intended way to start a server. The server will be
started on a dynamically allocated port, with a random SHA-256
username and password. These credentials will be published to the
server's session file, which is accessible only to the user.

If you would like more control over the server (for example,
specifying the username, port or password) please refer to
`porthole-start-server-advanced'."
  (let ((username (porthole--random-sha256-key))
        (password (porthole--random-sha256-key)))
    (porthole-start-server-advanced name
                                :port 0
                                :username username
                                :password password
                                :publish-port t
                                :publish-username t
                                :publish-password t
                                :exposed-functions exposed-functions)))


(cl-defun porthole-start-server-advanced (server-name
                                      &key
                                      (port 0)
                                      (username nil)
                                      (password nil)
                                      (publish-port t)
                                      ;; TODO: Maybe combine into "publish-credentials"?
                                      (publish-username t)
                                      (publish-password t)
                                      (exposed-functions '()))
  "Start a new JSON-RPC 2.0 server.

JSON-RPC requests to the server should be sent in the body of
POST requests. They should be sent according to the JSON-RPC 2.0
specification, although the server will also tolerate JSON-RPC
1.x requests. JSON-RPC protocols >2.0 are not supported.

# Port

  The server will be allocated a random port when it is started.
  This will be printed to the message buffer. Use the keyword
  argument `:PORT' to specify a port to the server.

  If the port is dynamically allocated, clients need to be able
  to discover it. To achieve this, port information can be
  written to a known file in the user's home dir. The flag
  `:PUBLISH-PORT' controls whether this file is created or not.
  By default, it is t, meaning the port information will be
  published.

  See the README for a full explanation of how to configure
  clients.

# Authentication

  The server optionally supports Basic Access Authentication to
  authenticate RPC requests:

    https://en.wikipedia.org/wiki/Basic_access_authentication

  By default, the server will be started with no authentication.
  If you would like to use Basic Access Authentication, specify
  the keyword arguments `:USERNAME' or `:PASSWORD'. You do not
  need to provide both (although it is obviously recommended).
  For example, if you provide only a password, the empty string
  will be used for the username.

Note that this method will fail if the server is already
running."
  ;; TODO: server-name restriction. Only certain chars.
  (porthole--assert-server-not-running server-name)
  ;; We have to handle dynamic ports differently.
  (if (member port '("0" 0 t))
      ;; Get a dynamic port. Please note, this CAN PRODUCE A RACE CONDITION if the
      ;; port is grabbed between this check and starting the server.
      ;;
      ;; This is necessary because Elnode stores a server started on port 0, in...
      ;; The port 0 slot. So you can only start one server on port 0.
      ;;
      ;; Because this can produce a race condition, we try multiple times just in
      ;; case that race condition pops up.
      (let (
            ;; Try to claim a dynamic port this many times. The chance of the race
            ;; condition occurring 500 times is infinitesimally small.
            (max-attempts 500))
        (unless (catch 'server-started
                  (dotimes (i max-attempts)
                    (setq port (porthole--find-free-port "localhost"))
                    (condition-case err
                        ;; Try and start the server with these parameters.
                        ;;
                        ;; If the port is taken, it will throw a file-error. If
                        ;; Elnode already has a server running on this port (it
                        ;; shouldn't, but just in case), the server creation
                        ;; process will fail silently, and return nil. Handle
                        ;; both cases.
                        (when (elnode-start
                               'porthole--handle-request
                               :port port
                               :host "localhost")
                          ;; If the server was started successfully, we're done. We
                          ;; have a server - break out and continue.
                          (throw 'server-started t))
                      (file-error nil)
                      (error
                       (signal (car err) (cdr err))))
                    (throw 'server-started nil)))
          ;; If the server could not be started after many retries, we just raise an error.
          (error "%s" (format (concat
                               "Tried to start on a free port %s times."
                               " Failed each time. Server could not be started.")
                              max-attempts))))
    (when (alist-get port elnode-server-socket)
      (error "Elnode already has a server running on this port."))
    (elnode-start
     'porthole--handle-request
     :port port
     :host "localhost"))
  ;; If we've reached this point, the server has started successfully.
  (push (cons server-name (make-porthole--server
                           :name server-name
                           :port port
                           :username username
                           :password password
                           :exposed-functions exposed-functions
                           ;; We store the actual Elnode server process too, in case we
                           ;; wish to query it directly.
                           :elnode-process (alist-get port elnode-server-socket)))
        porthole--running-servers)
  ;; We ensure the servers will be stopped when Emacs is closed.
  (add-hook 'kill-emacs-hook 'porthole--stop-all-servers)
  (message "porthole \"%s\" running on port %s" server-name port)
  (porthole--publish-session-file
   server-name port username password
   :publish-port publish-port
   :publish-username publish-username
   :publish-password publish-password)
  server-name)


(defun porthole-stop-server (server-name)
  "Stop the active JSON-RPC 2.0 server.

This method will fail if no server is running."
  ;; Erase the server info file up front - it may exist even though the server
  ;; isn't running.
  (porthole--erase-session-file server-name)
  (porthole--assert-server-running server-name)
  (let* ((server (porthole--get-server server-name))
         (port (porthole--server-port server)))
    ;; Stop the actual HTTP process
    (elnode-stop port)
    ;; Remove the server from the list of running servers.
    (setq porthole--running-servers
          (porthole--alist-remove server-name porthole--running-servers))))


(defun porthole--stop-server-safe (server-name &rest _)
  "Like `porthole-stop-server', but this function will not raise errors."
  (ignore-errors (porthole-stop-server server-name)))


(defun porthole--stop-all-servers (&rest _)
  "Stop all running PORTHOLE servers.

Their session information files will be cleaned up.

This function is not intended to be used by the end-user. It
should only be called when, for example, Emacs is closing."
  (mapc 'porthole--stop-server-safe
        (porthole--running-server-names)))


(defun porthole-expose-function (func server-name)
  "Expose a function to remote procedure calls on a particular RPC server.

Only functions that have been exposed on that server can be
executed remotely via its API.

`FUNC' is the function symbol to expose. Functions may only be
invoked by name. Lambda functions are not allowed (there would be
no way for the client to reference them by name).

`SERVER-NAME' is the name of the server on which the function
should be exposed."
  (unless (symbolp func)
    (error "`func' should be a symbol. Was type: %s. Value: %s"
           (type-of func) func))
  (porthole--assert-server-running server-name)
  (let ((server (porthole--get-server server-name)))
    (setf (porthole--server-exposed-functions server)
          (append (porthole--server-exposed-functions server)
                  (list func)))))


(defun porthole-hide-function (func server-name)
  "Hide a function from remote procedure calls on a server.

`FUNC' is the function symbol to hide.

`SERVER-NAME' is the name of the server on which the function
should be hidden.

This reverses `porthole-expose-function'."
  (unless (symbolp func)
    (error "`func' should be a symbol. Was type: %s. Value: %s"
           (type-of func) func))
  (porthole--assert-server-running server-name)
  (let ((server (porthole--get-server server-name)))
    (setf (porthole--server-exposed-functions server)
          (porthole--alist-remove func (porthole--server-exposed-functions server)))))


(provide 'porthole)
;;; porthole.el ends here
