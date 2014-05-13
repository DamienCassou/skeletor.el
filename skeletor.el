;;; skeletor.el --- Provides project skeletons for Emacs  -*- lexical-binding: t; -*-

;; Copyright (C) 2013 Chris Barrett

;; Author: Chris Barrett <chris.d.barrett@me.com>
;; Package-Requires: ((s "1.7.0") (f "0.14.0") (dash "2.2.0") (cl-lib "0.3") (emacs "24.1"))
;; Version: 1.2.2

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or modify
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

;; Provides project skeletons for Emacs.
;;
;; To create a new project interactively, run 'M-x skeletor-create-project'.
;;
;; To define a new project, create a project template inside
;; `skeletor-user-directory', then configure the template with the
;; `skeletor-define-template' macro.
;;
;; See the info manual for all the details.

;;; Code:

(require 'dash)
(require 's)
(require 'f)
(require 'cl-lib)
(autoload 'insert-button "button")
(autoload 'comint-mode "comint")

(defgroup skeletor nil
  "Provides customisable project skeletons for Emacs."
  :group 'tools
  :prefix "skeletor-"
  :link '(custom-manual "(skeletor)Top")
  :link '(info-link "(skeletor)Usage"))

(defcustom skeletor-user-directory (f-join user-emacs-directory "project-skeletons")
  "The directory containing project skeletons.
Each directory inside is available for instantiation as a project
skeleton."
  :group 'skeletor
  :type 'directory)

(defcustom skeletor-user-organisation nil
  "Used in template expansions to set the user organisation."
  :group 'skeletor
  :type '(choice (const :tag "None" nil)
                 (string :tag "Value")))

(defcustom skeletor-project-directory (f-join (getenv "HOME") "Projects")
  "The directory where new projects will be created."
  :group 'skeletor
  :type 'directory)

(defcustom skeletor-global-substitutions
  (list (cons "__YEAR__" (format-time-string "%Y"))
        (cons "__USER-NAME__" user-full-name)
        (cons "__USER-MAIL-ADDRESS__" user-mail-address)
        (cons "__ORGANISATION__" (lambda ()
                                   (or skeletor-user-organisation
                                       user-full-name))))
  "A list of substitutions available for expansion in all project skeletons.

Each alist element is comprised of (candidate . substitution),
where 'candidate' will be replaced with 'substitution'.
'substitution' may be a string literal, a variable that will be
evaluated or a function that will be called."
  :group 'skeletor
  :type '(alist :key-type 'string
                :value-type (choice string variable function)))

(defcustom skeletor-init-with-git (executable-find "git")
  "When non-nil, initialise newly created projects with a git repository."
  :group 'skeletor
  :type 'boolean)

(defcustom skeletor-show-project-command 'dired
  "The command to use to show newly-created projects.
Should be a function that accepts the path to the project as an
argument."
  :group 'skeletor
  :type 'function)

(defcustom skeletor-completing-read-function 'ido-completing-read
  "Function to be called when requesting input from the user."
  :group 'skeletor
  :type '(radio (function-item completing-read)
                (function :tag "Other")))

(defcustom skeletor-after-project-instantiated-hook nil
  "Hook run after a project is successfully instantiated.
Each function will be passed the path of the newly instantiated
project."
  :group 'skeletor
  :type 'hook)

(defcustom skeletor-shell-setup-finished-hook nil
  "Hook run after a project has been set up using `skeletor-with-shell-setup'.
Each function should accept a single argument that is the project path."
  :group 'skeletor
  :type 'hook)

(defgroup skeletor-python nil
  "Configuration for python projects in Skeletor."
  :group 'tools
  :prefix "skeletor-python-")

(defcustom skeletor-python-bin-search-path '("/usr/bin" "/usr/local/bin")
  "A list of paths to search for python binaries.

Python binaries found in these paths will be shown as canditates
when initialising virtualenv."
  :group 'skeletor-python
  :type '(repeat directory))

(defgroup skeletor-haskell nil
  "Configuration for haskell projects in Skeletor."
  :group 'tools
  :prefix "skeletor-haskell-")

(defcustom skeletor-hs-main-file-content
  "module Main where

main :: IO ()
main = undefined
"
  "The contents to insert when creating a Haskell main file."
  :group 'skeletor-haskell
  :type 'string)

(defcustom skeletor-hs-library-file-content-format
  "module %s where
"
  "Format string used to generate the contents of a new Haskell library file.
The format string should have one `%s' specfier, which is
replaced with the module name."
  :group 'skeletor-haskell
  :type 'string)

;;; -------------------------- Public Utilities --------------------------------

(defun skeletor-shell-command (dir command &optional no-assert)
  "Run a shell command and return its exit status.

* DIR is an unquoted path at which to run the command.

* COMMAND is the shell command to execute.

* An error will be raised on a non-zero result, unless NO-ASSERT
  is t."
  (let ((buf (get-buffer-create (format "*Skeletor [%s]*" (f-filename dir)))))
    (with-current-buffer buf
      (erase-buffer))
    (let ((result (shell-command (format "cd %s && %s" (shell-quote-argument dir) command)
                                 buf
                                 (format "*Skeletor Errors [%s]*" (f-filename dir)))))
      (unless no-assert
        (cl-assert (zerop result) nil
                   "Skeleton creation failed--see the output buffer for details"))
      result)))

(defun skeletor-async-shell-command (dir command)
  "Run an async shell command.

* DIR is an unquoted path at which to run the command.

* COMMAND is the shell command to execute."
  (let ((buf (get-buffer-create
              (generate-new-buffer-name
               (format "*Skeletor [%s]*" (f-filename dir))))))
    (with-current-buffer buf
      (erase-buffer))
    (async-shell-command
     (format "cd %s && %s" (shell-quote-argument dir) command)
     buf
     (format "*Skeletor Errors [%s]*" (f-filename dir)))))

(defvar skeletor--interactive-process nil
  "The current interactive shell process.  See `skeletor-with-shell-setup'.")

(defun skeletor-with-shell-setup (dir cmd callback)
  "Perform template setup using an interactive shell command.
Display the shell buffer for user input.

DIR will be used as the current directory.

CMD is the shell command to call.

If the command exits successfully,

- delete the shell buffer

- execute CALLBACK

- run `skeletor-shell-setup-finished-hook'.

This is intended to be used in the 'after-setup' stage of a
template declaration."
  (declare (indent 2))
  (let ((bufname "*Skeletor Interactive Setup*"))
    (setq skeletor--interactive-process
          (start-process-shell-command
           "skeletorcmd" bufname
           (format "cd %s && %s" dir cmd)))
    (condition-case nil
        (progn
          (set-process-sentinel
           skeletor--interactive-process
           `(lambda (proc str)
              (setq skeletor--interactive-process nil)
              (when (s-matches? "finished" str)
                (kill-buffer (process-buffer proc))
                (funcall ,callback)
                (run-hook-with-args 'skeletor-shell-setup-finished-hook ,dir))))
          (switch-to-buffer bufname)
          (comint-mode))
      (error
       (setq skeletor--interactive-process nil)))))

(defun skeletor-require-executables (alist)
  "Check that executables can be located in the `exec-path'.
Show a report with installation instructions if any cannot be
found.

ALIST is a list of `(PROGRAM-NAME . URL)', where URL points to
download instructions."
  (-when-let (not-found (--remove (executable-find (car it)) alist))
    (let ((buf (get-buffer-create "*Skeletor Rage*")))
      (with-help-window buf
        (with-current-buffer buf
          (insert (concat
                   "This template requires external tools which "
                   "could not be found.\n\n"
                   "See each item below for installation instructions.\n"))
          (--each not-found
            (cl-destructuring-bind (program . url) it
              (insert "\n - ")
              (insert-button program
                             'action (lambda (x) (browse-url (button-get x 'url)))
                             'url url))))))
    (user-error "Cannot find executable(s) needed to create project")))

;;; ----------------------------- Internal -------------------------------------

(defvar skeletor--pkg-root (f-dirname (or load-file-name (buffer-file-name)))
  "The base directory of the Skeletor package.")

(defvar skeletor--directory
  (f-join skeletor--pkg-root "project-skeletons")
  "The directory containing built-in project skeletons.
Each directory inside is available for instantiation as a project
skeleton.")

(defvar skeletor--project-types nil
  "A list of SkeletorProjectType that represents the available templates.")

(defvar skeletor--licenses-directory (f-join skeletor--pkg-root "licenses")
  "The directory containing license files for projects.")

(cl-defstruct (SkeletorTemplate
               (:constructor SkeletorTemplate (path files dirs)))
  "Represents a project template.

* PATH is the path to this project template.

* DIRS is a list of all directories in the filesystem tree beneath PATH.

* FILES is a list of all files in the filesystem tree beneath PATH."
  path files dirs)

(cl-defstruct (SkeletorExpansionSpec
               (:constructor SkeletorExpansionSpec (files dirs)))
  "Represents a project template with expanded filenames.

* DIRS is a list of conses, where the car is a path to a dir in
  the template and the cdr is that dirname with all substitutions performed.

* FILES is a list of conses, where the car is a path to a file in
  the template and the cdr is that filename with all substitutions
  performed."
  files dirs)

(cl-defstruct (SkeletorProjectType
               (:constructor SkeletorProjectType (title constructor)))
  "Represents a project type that can be created by the user.

* TITLE is the string representation of the template to be shown
  in the UI.

* CONSTRUCTOR is a command to call to construct an instance of the skeleton."
  title constructor)

;; FilePath -> IO SkeletorTemplate
(defun skeletor--dir->SkeletorTemplate (path)
  "Construct a SkeletorTemplate from the filesystem entries at PATH."
  (SkeletorTemplate path (f-files path nil t) (f-directories path nil t)))

;; [(String,String)], FilePath -> SkeletorExpansionSpec
(defun skeletor--expand-template-paths (substitutions dest template)
  "Expand all file and directory names in a template.
Return a SkeletorExpansionSpec.

* SUBSTITUTIONS is an alist as accepted by `s-replace-all'.

* DEST is the destination path for the template.

* TEMPLATE is a SkeletorTemplate."
  (cl-assert (stringp dest))
  (cl-assert (listp substitutions))
  (cl-assert (SkeletorTemplate-p template))
  (cl-flet ((expand (it)
                    (->> (skeletor--replace-all substitutions it)
                      (s-chop-prefix (SkeletorTemplate-path template))
                      (s-prepend (s-chop-suffix (f-path-separator) dest)))))
    (SkeletorExpansionSpec
     (--map (cons it (expand it)) (SkeletorTemplate-files template))
     (--map (cons it (expand it)) (SkeletorTemplate-dirs template)))))

(defun skeletor--evaluate-elisp-exprs-in-string (str)
  "Evaluate any elisp expressions in string STR.
An expression has the form \"__(expr)__\"."
  (with-temp-buffer
    (insert str)
    (goto-char (point-min))
    (let ((sexp-prod (rx "__" (group "(" (+? anything)")") "__")))
      (while (search-forward-regexp sexp-prod nil t)
        (replace-match (pp-to-string (eval (read (match-string 1)))) t)))
    (buffer-string)))

;; [(String,String)], String -> String
(defun skeletor--replace-all (substitutions str)
  "Expand SUBSTITUTIONS in STR with fixed case.
Like `s-replace-all' but preserves case of the case of the
substitution."
  (let ((expanded (skeletor--evaluate-elisp-exprs-in-string str)))
    (if substitutions
        (replace-regexp-in-string (regexp-opt (-map 'car substitutions))
                                  (lambda (it) (cdr (assoc it substitutions)))
                                  expanded 'fixcase)
      expanded)))

(defun skeletor--validate-substitutions (alist)
  "Assert that ALIST will be accepted by `s-replace-all'."
  (cl-assert (listp alist))
  (cl-assert (--all? (stringp (car it)) alist))
  (cl-assert (--all? (stringp (cdr it)) alist)))

;; [(String,String)], SkeletorExpansionSpec -> IO ()
(defun skeletor--instantiate-spec (substitutions spec)
  "Create an instance of the given template specification.

* SUBSTITUTIONS is an alist as accepted by `s-replace-all'.

* SPEC is a SkeletorExpansionSpec."
  (skeletor--validate-substitutions substitutions)
  (cl-assert (SkeletorExpansionSpec-p spec))
  (--each (-map 'cdr (SkeletorExpansionSpec-dirs spec))
    (make-directory it t))
  (--each (SkeletorExpansionSpec-files spec)
    (cl-destructuring-bind (src . dest) it
      (f-touch dest)
      (f-write (skeletor--replace-all substitutions (f-read src))
               'utf-8 dest))))

;; [(String,String)], FilePath, FilePath -> IO ()
(defun skeletor--instantiate-skeleton-dir (substitutions src dest)
  "Create an instance of a project skeleton.

* SUBSTITUTIONS is an alist as accepted by `s-replace-all'.

* SRC is the path to the template directory.

* DEST is the destination path for the template."
  (skeletor--validate-substitutions substitutions)
  (cl-assert (stringp src))
  (cl-assert (f-exists? src))
  (cl-assert (stringp dest))
  (make-directory dest t)
  (->> (skeletor--dir->SkeletorTemplate src)
    (skeletor--expand-template-paths substitutions dest)
    (skeletor--instantiate-spec substitutions)))

;; FilePath -> IO ()
(defun skeletor--initialize-git-repo  (dir)
  "Initialise a new git repository at DIR."
  (message "Initialising git...")
  ;; Some tools (e.g. bundler) initialise git but do not make an initial
  ;; commit.
  (unless (f-exists? (f-join dir ".git"))
    (skeletor-shell-command dir "git init"))
  (skeletor-shell-command
   dir "git commit --allow-empty -m 'Initial commit'")
  (skeletor-shell-command
   dir "git add -A && git commit -m 'Add initial files'")
  (message "Initialising git...done"))

;; FilePath, FilePath, [(String,String)] -> IO ()
(defun skeletor--instantiate-license-file (license-file dest substitutions)
  "Populate the given license file template.

* LICENSE-FILE is the path to the template license file.

* DEST is the path it will be copied to.

* SUBSTITUTIONS is an alist passed to `skeletor--replace-all'."
  (f-write (skeletor--replace-all substitutions (f-read license-file)) 'utf-8 dest))

;; FilePath -> IO ()
(defun skeletor--show-project (dest)
  "Reveal the new project at DEST by calling `skeletor-show-project-command'."
  (when skeletor-show-project-command
    (if skeletor--interactive-process
        (add-hook 'skeletor-shell-setup-finished-hook
                  skeletor-show-project-command)
      (funcall skeletor-show-project-command dest))))

;; FilePath -> IO ()
(defun skeletor--prepare-git (dest)
  "Configure a git repo at DEST at an appropriate stage in the setup.
If there is an interactive process, wait until that is finished.
Otherwise immediately initialise git."
  (when skeletor-init-with-git
    (if skeletor--interactive-process
        (add-hook 'skeletor-shell-setup-finished-hook
                  'skeletor--initialize-git-repo)
      (skeletor--initialize-git-repo dest))))

;;; ---------------------- User Interface Commands -----------------------------

;; (String,String) -> IO (String,String)
(cl-defun skeletor--eval-substitution ((token . repl))
  "Convert a substitution item according to the following rules:

* If the item is a lambda-function or function-name it will be called

* If it is a symbol will be eval'ed

* Otherwise the item will be used unchanged."
  (cons token (cond ((functionp repl)
                     (if (commandp repl)
                         (call-interactively repl)
                       (funcall repl)))
                    ((symbolp repl)
                     (eval repl))
                    (t
                     repl))))

;; String, Regex -> IO FilePath
(defun skeletor--read-license (prompt default)
  "Prompt the user to select a license.

* PROMPT is the prompt shown to the user.

* DEFAULT a regular expression used to find the default."
  (let* ((xs (--map (cons (s-upcase (f-filename it)) it)
                    (f-files skeletor--licenses-directory)))
         (d (unless (s-blank? default)
              (car (--first (s-matches? default (car it)) xs))))
         (choice (funcall skeletor-completing-read-function
                          prompt (-map 'car xs) nil t d)))
    (cdr (assoc choice xs))))

;; {String} -> IO String
(cl-defun skeletor--read-project-name (&optional (prompt "Project Name: "))
  "Read a project name from the user."
  (let* ((name (read-string prompt))
         (dest (f-join skeletor-project-directory name)))
    (cond
     ((s-blank? name)
      (skeletor--read-project-name))
     ((f-exists? dest)
      (skeletor--read-project-name
       (format "%s already exists. Choose a different name: " dest)))
     (t
      name))))

;;; --------------------- Public Commands and Macros ---------------------------

;;;###autoload
(cl-defmacro skeletor-define-template (name
                                       &key
                                       title
                                       substitutions
                                       (after-creation 'ignore)
                                       no-license?
                                       default-license
                                       (license-file-name "COPYING")
                                       requires-executables)
  "Declare a new project type.

* NAME is a string naming the project type. A corresponding
  skeleton should exist in `skeletor--directory' or
  `skeletor-user-directory'.

* TITLE is the name to use when referring to this project type in
  the UI.

* SUBSTITUTIONS is an alist of (string . substitution) specifying
  substitutions to be used, in addition to the global
  substitutions defined in `skeletor-global-substitutions'. These
  are evaluated when creating an instance of the template.

* When NO-LICENSE? is t, the project will not be initialised with
  a license file.

* DEFAULT-LICENSE is a regexp matching the name of a license to
  be used as the default. This default is used to pre-populate
  the license prompt when creating an insance of the template.

* LICENSE-FILE-NAME is the filename to use for the generated
  license file.

* AFTER-CREATION is a unary function to be run once the project
  is created. It should take a single argument--the path to the
  newly-created project.

* REQUIRES-EXECUTABLES is an alist of `(PROGRAM . URL)'
  expressing programs needed to expand this skeleton. See
  `skeletor-require-executables'."
  (declare (indent 1))
  (cl-assert (stringp name) t)
  (cl-assert (or (null title) (stringp title)) t)
  (cl-assert (stringp license-file-name) t)
  (cl-assert (functionp after-creation) t)
  (let ((constructor (intern (format "skeletor--create-%s" name)))
        (title (or title (s-join " " (-map 's-capitalize (s-split-words name)))))
        (default-license-var (intern (format "%s-default-license" name)))
        (rs (eval substitutions))
        (exec-alist (eval requires-executables)))

    (cl-assert (listp requires-executables) t)
    (cl-assert (-all? 'stringp (-map 'car exec-alist)) t)
    (cl-assert (-all? 'stringp (-map 'cdr exec-alist)) t)

    (cl-assert (listp rs) t)
    (cl-assert (-all? 'stringp (-map 'car rs)) t)

    `(progn
       (defvar ,default-license-var ,default-license
         ,(concat "Auto-generated variable.\n\n"
                  "The default license type for " name " skeletons.") )
       ;; Update the variable if the definition is re-evaluated.
       (setq ,default-license-var ,default-license)

       (defun ,constructor ()
         ;; Docstring
         ,(concat
           "Auto-generated function.\n\n"
           "Interactively creates a new " name " skeleton.")
         ;; Body
         (skeletor-require-executables ',exec-alist)
         (let* ((project-name (skeletor--read-project-name))
                (license-file
                 (unless ,no-license?
                   (skeletor--read-license "License: " (eval ,default-license-var))))
                (dest (f-join skeletor-project-directory project-name))
                (default-directory dest)
                (repls (-map 'skeletor--eval-substitution
                             (-concat
                              skeletor-global-substitutions
                              (list (cons "__PROJECT-NAME__" project-name)
                                    (cons "__LICENSE-FILE-NAME__" ,license-file-name))
                              ',rs))))

           ;; Instantiate the project.

           (-if-let (skeleton (-first 'f-exists?
                                      (list (f-expand ,name skeletor-user-directory)
                                            (f-expand ,name skeletor--directory))))
               (progn
                 (unless (f-exists? skeletor-project-directory)
                   (make-directory skeletor-project-directory t))
                 (skeletor--instantiate-skeleton-dir repls skeleton dest)

                 (when license-file
                   (skeletor--instantiate-license-file
                    license-file (f-join dest ,license-file-name) repls)))

             (error "Skeleton %s not found" ,name))

           (funcall #',after-creation dest)
           (skeletor--prepare-git dest)
           (run-hook-with-args 'skeletor-after-project-instantiated-hook dest)
           (skeletor--show-project dest)
           (message "Project created at %s" dest)))

       (add-to-list 'skeletor--project-types
                    (SkeletorProjectType ,(or title name) ',constructor)))))

;;;###autoload
(cl-defmacro skeletor-define-constructor (title
                                          &key
                                          initialise
                                          (after-creation 'ignore)
                                          no-git?
                                          no-license?
                                          default-license
                                          (license-file-name "COPYING")
                                          requires-executables)
  "Define a new project type with a custom way of constructing a skeleton.
This can be used to add bindings for command-line tools.

* TITLE is a string naming the project type in the UI.

* INITIALISE is a binary function that creates the project
  structure. It will be passed a name for the project, read from
  the user, and the current value of `skeletor-project-directory'.

  INITIALISE is expected to initialise the new project at
  skeletor-project-directory/NAME. The command should signal an error
  if this fails for any reason.

  Make sure to switch to a shell buffer if INITIALISE is a shell
  command that requires user interaction.

* AFTER-CREATION is a unary function to be run once the project
  is created. It should take a single argument--the path to the
  newly-created project.

* When NO-GIT? is t, the project will not be initialised with a
  git repo, regardless of the value of `skeletor-init-with-git'.

* When NO-LICENSE? is t, the project will not be initialised with
  a license file.

* DEFAULT-LICENSE is a regexp matching the name of a license to
  be used as the default. This default is used to pre-populate
  the license prompt when creating an insance of the template.

* LICENSE-FILE-NAME is the filename to use for the generated
  license file.

* REQUIRES-EXECUTABLES is an alist of `(PROGRAM . URL)'
  expressing programs needed to expand this skeleton. See
  `skeletor-require-executables'."
  (declare (indent 1))
  (cl-assert (stringp title) t)
  (cl-assert (stringp license-file-name) t)
  (cl-assert (functionp initialise) t)
  (cl-assert (functionp after-creation) t)
  (let* ((project-symbol-name (s-replace " " "-" (s-downcase title)))
         (constructor (intern (concat "skeletor--create-" project-symbol-name)))
         (default-license-var (intern
                               (concat project-symbol-name "-default-license")))
         (exec-alist (eval requires-executables)))
    (cl-assert (listp requires-executables) t)
    (cl-assert (-all? 'stringp (-map 'car exec-alist)) t)
    (cl-assert (-all? 'stringp (-map 'cdr exec-alist)) t)

    `(progn

       (defvar ,default-license-var ,default-license
         ,(concat "Auto-generated variable.\n\n"
                  "The default license type for " title " skeletons.") )
       ;; Update the variable if the definition is re-evaluated.
       (setq ,default-license-var ,default-license)


       (defun ,constructor ()
         ;; Docstring
         ,(concat "Auto-generated function.\n\n"
                  "Creates a new " title " skeleton.")
         ;; Body
         (skeletor-require-executables ',exec-alist)
         (let* ((project-name (skeletor--read-project-name))
                (license-file
                 (unless ,no-license?
                   (skeletor--read-license "License: " (eval ,default-license-var))))
                (dest (f-join skeletor-project-directory project-name))
                (default-directory dest)
                (repls (-map 'skeletor--eval-substitution
                             (-concat
                              skeletor-global-substitutions
                              (list (cons "__PROJECT-NAME__"
                                          project-name)
                                    (cons "__LICENSE-FILE-NAME__"
                                          ,license-file-name))))))

           (unless (f-exists? skeletor-project-directory)
             (make-directory skeletor-project-directory t))
           (funcall #',initialise project-name skeletor-project-directory)
           (cl-assert (f-exists? dest) t
                      "Initialisation function failed to create project at %s")

           (funcall #',after-creation dest)
           (when license-file
             (skeletor--instantiate-license-file
              license-file (f-join dest ,license-file-name) repls))
           (unless ,no-git?
             (skeletor--prepare-git dest))
           (run-hook-with-args 'skeletor-after-project-instantiated-hook dest)
           (skeletor--show-project dest)
           (message "Project created at %s" dest)))

       (add-to-list 'skeletor--project-types (SkeletorProjectType ,title ',constructor)))))

;;;###autoload
(defun skeletor-create-project (title)
  "Interactively create a new project with Skeletor.
TITLE is the name of an existing project skeleton."
  (interactive
   (list (completing-read "Skeleton: "
                          (->> skeletor--project-types
                            (-map 'SkeletorProjectType-title)
                            (-sort 'string<))
                          nil t)))

  (funcall (->> skeletor--project-types
             (--first (equal title (SkeletorProjectType-title it)))
             SkeletorProjectType-constructor)))

;;; ------------------------ Built-in skeletons --------------------------------

(skeletor-define-template "elisp-package"
  :title "Elisp Package"
  :requires-executables '(("make" . "http://www.gnu.org/software/make/")
                          ("cask" . "https://github.com/cask/cask"))
  :default-license (rx bol "gpl")
  :substitutions
  '(("__DESCRIPTION__"
     . (lambda ()
         (read-string "Description: "))))
  :after-creation
  (lambda (dir)
    (skeletor-async-shell-command dir "make env")))

(skeletor-define-template "elisp-package-with-docs"
  :title "Elisp Package (with documentation)"
  :requires-executables '(("make" . "http://www.gnu.org/software/make/")
                          ("cask" . "https://github.com/cask/cask"))
  :default-license (rx bol "gpl")
  :substitutions
  '(("__DESCRIPTION__"
     . (lambda ()
         (read-string "Description: "))))
  :after-creation
  (lambda (dir)
    (skeletor-async-shell-command dir "make env")))

(defun skeletor-py--read-python-bin ()
  "Read a python binary from the user."
  (->> skeletor-python-bin-search-path
    (--mapcat
     (f-files it (lambda (f)
                   (s-matches? (rx "python" (* (any digit "." "-")) eol)
                               f))))
    (funcall skeletor-completing-read-function "Python binary: ")))

(skeletor-define-template "python-library"
  :title "Python Library"
  :requires-executables '(("make" . "http://www.gnu.org/software/make/")
                          ("virtualenv" . "http://www.virtualenv.org"))
  :substitutions '(("__PYTHON-BIN__" . skeletor-py--read-python-bin))
  :after-creation
  (lambda (dir)
    (skeletor-async-shell-command dir "make tooling")))

(defun skeletor-hs--cabal-sandboxes-supported? ()
  "Non-nil if the installed cabal version supports sandboxes.
Sandboxes were introduced in cabal 1.18 ."
  (let ((vers (->> (shell-command-to-string "cabal --version")
                (s-match (rx (+ (any num "."))))
                car
                (s-split (rx "."))
                (-map 'string-to-int))))
    (cl-destructuring-bind (maj min &rest rest) vers
      (or (< 1 maj) (<= 18 min)))))

(defun skeletor-hs--post-process-cabal-file (file)
  "Adjust fields in the cabal file.  FILE is the cabal file path."
  (with-current-buffer (find-file-noselect file)
    (goto-char (point-min))
    ;; Set src dir.
    (save-excursion
      (when (search-forward-regexp (rx (* space)
                                       (group-n 1 "--" (* space))
                                       "hs-source-dirs:" (* space) eol)
                                   nil t)
        (replace-match "" nil nil nil 1)
        (goto-char (line-end-position))
        (indent-to 23)
        (insert "src")))

    ;; Set main file.
    (save-excursion
      (when (search-forward-regexp (rx (* space)
                                       (group-n 1 "--" (* space))
                                       "main-is:" (* space) eol)
                                   nil t)
        (replace-match "" nil nil nil 1)
        (goto-char (line-end-position))
        (indent-to 23)
        (insert "Main.hs")))

    (save-buffer)
    (kill-buffer)))

(defun skeletor-hs--init-src-file (cabal-file src-dir)
  "Create either a Main.hs file or a toplevel library file.

CABAL-FILE is the path to the project's cabal file.

SRC-DIR is the path to the project src directory."
  (let* ((executable? (s-contains? "main-is:" (f-read-text cabal-file)))
         (module-name
          (if executable?
              "Main"
            (->> (f-base (f-parent cabal-file))
              s-split-words
              (-map 's-capitalize)
              (s-join ""))))
         (path
          (f-join src-dir
                  (if executable? "Main.hs" (concat module-name ".hs"))))
         (str (if executable?
                  skeletor-hs-main-file-content
                (format skeletor-hs-library-file-content-format
                        module-name)))
         )
    (f-write str 'utf-8 path)))

(skeletor-define-template "haskell-project"
  :title "Haskell Project"
  :requires-executables '(("cabal" . "http://www.haskell.org/cabal/"))
  :no-license? t
  :after-creation
  (lambda (dir)
    (when (skeletor-hs--cabal-sandboxes-supported?)
      (message "Initialising sandbox...")
      (skeletor-shell-command dir "cabal sandbox init"))

    (skeletor-with-shell-setup dir "cabal init"
      (lambda ()
        (let ((cabal-file (car (f-entries dir (lambda (f) (equal "cabal" (f-ext f))))))
              (src-dir (f-join dir "src")))
          (skeletor-hs--post-process-cabal-file cabal-file)
          (f-mkdir src-dir)
          (skeletor-hs--init-src-file cabal-file src-dir))))))

(skeletor-define-constructor "Ruby Gem"
  :requires-executables '(("bundle" . "http://bundler.io"))
  :no-license? t
  :initialise
  (lambda (name project-dir)
    (skeletor-shell-command
     project-dir (format "bundle gem %s" (shell-quote-argument name))))
  :after-creation
  (lambda (dir)
    (when (and (executable-find "rspec")
               (y-or-n-p "Create RSpec test suite? "))
      (skeletor-shell-command dir "rspec --init"))))

(defvar skeletor-clj--project-types-cache nil
  "A list of strings representing the available Leiningen templates.")

(defun skeletor-clj--project-types ()
  "Parse the project templates known to Leiningen.
Return a list of strings representing the available templates.

This is a lengthy operation so the results are cached to
`skeletor-clj--project-types-cache'."
  (or skeletor-clj--project-types-cache
      (let ((types (->> (shell-command-to-string "lein help new")
                     (s-match
                      (rx bol "Subtasks available:\n" (group (+? anything)) "\n\n"))
                     cadr
                     (s-split "\n")
                     (--keep (cadr (s-match (rx bol (* space) (group (+ (not space))))
                                            it))))))
        (prog1 types
          (setq skeletor-clj--project-types-cache types)))))

(skeletor-define-constructor "Clojure Project"
  :requires-executables '(("lein" . "http://leiningen.org/"))
  :initialise
  (lambda (name project-dir)
    (message "Finding Leningen templates...")
    (let ((type (funcall skeletor-completing-read-function
                         "Template: " (skeletor-clj--project-types) nil t "default")))
      (skeletor-shell-command project-dir (format "lein new %s %s"
                                                  (shell-quote-argument type)
                                                  (shell-quote-argument name))))))

(provide 'skeletor)

;;; skeletor.el ends here
