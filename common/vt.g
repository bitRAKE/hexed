; Frame-buffer notation.
;
; Every visible change this program makes is composed into one buffer and
; handed to WriteFile once. Nothing writes to the console directly, because a
; WriteFile per fragment is the single largest cost in a console program and
; the whole point of the exercise is a display that stays cheap while the user
; navigates.
;
;       <| 27,'[?25l' |>
;
; appends a constant fragment at RDI, the frame-buffer write pointer:
;
;       lea rsi, [fragment]
;       mov ecx, sizeof fragment
;       rep movsb
;
; GLOBSTR pools the fragments and folds duplicates, so the dozens of `27,'[m'`
; in the paint routines cost three bytes of read-only data in total.
;
; Taken from the `<|...|>` interceptor in fasm2/examples/conio/console.inc. The
; companion `<<...>>` form — assemble a WriteFile on the spot — is deliberately
; not carried over: a routine that writes on its own breaks the one-frame,
; one-write rule that everything here is built around.
;
; Clobbers RSI and RCX; advances RDI. DF is zero throughout on Windows.

if ~ definite HEXED_VT_INCLUDED
HEXED_VT_INCLUDED := 1

calminstruction ? line&
	local var,i
	match <| line |>, line
	jno done
	init i, 0
	; A `.`-prefixed name is local to the enclosing procedure, and `i` is a
	; CALM variable initialised once and bumped per expansion, so the label
	; is unique across the module. GLOBSTR is a struc: it defines the name.
	arrange var, .=frag.i
	compute i, i + 1
	arrange line, var =GLOBSTR line
	assemble line
	arrange line, =lea =rsi, [var]
	assemble line
	arrange line, =mov =ecx, =sizeof var
	assemble line
	arrange line, =rep =movsb
done:	assemble line
end calminstruction

end if
