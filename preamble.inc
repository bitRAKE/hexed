; Shared hexed language environment. Module-specific SDK declarations stay
; in the modules: with pass-one restoration, a union prefix repeats work in
; the later passes of every module. Keep all CodeView lines and checksums.
if ~ definite HEXED_PREAMBLE_INCLUDED
HEXED_PREAMBLE_INCLUDED := 1

; Before the format, so newcoffcv.inc installs the verbose line tracker.
if ~ definite NEWCOFF.DEBUG
 NEWCOFF.DEBUG := 6
end if
include 'lowbase.inc'

; Static-RSP frames, wrapped so PROC/ENDP emit CodeView and unwind records;
; newcoff_debug_procs also records parameters and LOCALS as S_REGREL32.
prologue@proc equ newcoff_debug_prologue
close@proc equ newcoff_debug_close
newcoff_debug_procs

end if
