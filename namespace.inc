; Policy shared by every hexed object: the low fixed-base model and PROC/ENDP
; frames that describe themselves. The SDK headers are each module's own.
;
;       include 'namespace.inc'
;       include 'psdk\...'      ; the SDK headers this module uses
;       include 'hexed.h'       ; structures
;       include 'vt.inc'        ; then the `<| |>` catch-all
;
; vt.inc installs a `calminstruction ?` catch-all, and struct.inc's `struct`
; and `ends` move the whole `?` chain aside and back around each declaration
; (mvmacro/mvstruc). A catch-all present across that shuffle sends field
; declarations through the wrong handler and defines them twice, so the
; structures come first: the SDK's, from the module's headers, then hexed.h.

if ~ definite HEXED_NAMESPACE_INCLUDED
HEXED_NAMESPACE_INCLUDED := 1

; Editor project/build metadata is ordinary mutable fasmg namespace state.
if defined __EDITOR__
 namespace __EDITOR__?
  build.preamble = 'preamble.inc'
  project.modules.1 = 'view.asm'
  project.modules.2 = 'paint.asm'
  project.modules.3 = 'data_forms.asm'
  project.modules.4 = 'hexed.asm'
  build.hexed.steps.1 = 'link @hexed.response'
 end namespace
end if

; Shared language policy is also the editor's explicitly selected base.
include 'preamble.inc'

; Each module includes the SDK headers it uses, after this file and in one
; order: the base types (minwindef, windef, winnt); then kernel32 by subject -
; console, files and handles, memory, process, synchronization, text, and the
; WinBase catch-all last; then user32. A module that uses no SDK name includes
; none: data_forms.asm assembles in a fraction of the time hexed.asm takes.

end if
