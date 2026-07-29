; Executable policy shared by every hexed object.
;
; A module states its projection selection, then includes this file:
;
;       define win32.select.types system_console
;       define win32.select.downlevel kernel32
;       include '../common/policy.g'
;
; The selection has to precede windows.inc, which is why it belongs to the
; module rather than here. Only the parts that are the same for every object
; live in this file.
;
; Carried over from ../../controls/common/policy.g. The console program needs
; no comctl32 and no manifest, so the selection shrinks to kernel32, but the
; frame and debug-record machinery is identical and worth keeping identical.

if ~ definite HEXED_POLICY_INCLUDED
HEXED_POLICY_INCLUDED := 1

include 'dd.inc'
include 'align.inc'
include 'format.inc'
include 'x86-2.inc'
use AMD64

; Set before the format so newcoffcv.inc installs the verbose line tracker.
NEWCOFF.DEBUG := 6
format MS64 NEWCOFF

include 'macro/proc64.inc'
include 'generated/fasm2_calm/x64/windows.inc'

; Static-RSP frames, wrapped so PROC/ENDP emit CodeView and unwind records.
; newcoff_debug_procs additionally harvests declared parameters and LOCALS
; declarations as S_REGREL32 entries.
;
; SHIM. newcoff_debug_prologue and newcoff_debug_close (fasm2
; include/format/newcoffcv.inc, ~1075 and ~1085) take reglist as an ordinary
; parameter, which strips the grouping proc64 put around it, and forward it
; bare:
;
;       static_rsp_prologue procname,flag,parmbytes,localbytes,reglist
;
; With one USES register that is one argument and correct. With two or more it
; expands to `...,rbx ,rsi ,rdi` and static_rsp_prologue reports "extra
; characters on line" — so `proc X uses rbx rsi rdi` cannot be written at all.
; proc64.inc itself gets this right (`prologue name,...,reglist` where its own
; reglist still carries the group). Re-grouping on the way through is the whole
; fix. Delete these two macros once newcoffcv.inc carries it.
macro hexed_debug_prologue procname,flag,parmbytes,localbytes,reglist
	cvproc procname
	static_rsp_prologue procname,flag,parmbytes,localbytes,<reglist>
	match any, reglist
		cvframe framebytes@proc, reglist
	else
		cvframe framebytes@proc
	end match
end macro

macro hexed_debug_close procname,flag,parmbytes,localbytes,reglist
	cvendp
	static_rsp_close procname,flag,parmbytes,localbytes,<reglist>
end macro

prologue@proc equ hexed_debug_prologue
epilogue@proc equ static_rsp_epilogue
close@proc equ hexed_debug_close
newcoff_debug_procs

; After windows.inc, so the projection's finalizer is registered first and its
; imports are emitted ahead of these sections.
include 'data_blocks.g'

; vt.g is deliberately NOT included here.
;
; It installs a `calminstruction ?` catch-all, and `struct` moves the whole `?`
; chain aside and back around each declaration (mvmacro/mvstruc in struct.inc's
; `struct` and `ends`). A catch-all present across that shuffle leaves field
; declarations dispatching through the wrong handler, and the struct's fields
; are then defined twice — instantiating it reports
;
;       definition of 'HexState.hInput' in conflict with already defined symbol
;
; The projection's own types are declared above, before any catch-all exists,
; which is why they are unaffected and only locally declared structs break. So
; a module declares its structures first and picks up the notation afterwards:
;
;       include '../common/policy.g'
;       include '../hexed.h'            ; structures
;       include '../common/vt.g'        ; then the `<| |>` catch-all
;
; conio has the same constraint and satisfies it by accident: wincon.g is
; included before console.inc defines `<<...>>` and `<|...|>`, and it declares
; no structures of its own afterwards.

section '.text' code readable executable align 16

end if
