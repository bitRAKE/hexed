; Four-line interpretations of the bytes beginning at the active byte.
;
; F4 selects one family at a time. The selected family receives the expandable
; value field in its natural column; the other two families remain as compact
; row labels, so the three pages read as one rotating table:
;
;   f16 value...                         │ u8  │ s8
;   f16 │ u8 value...                           │ s8
;   f16 │ u8  │ s8                                      value...
;
; Integers are little-endian, comma-grouped decimal. Floating-point values are
; IEEE binary16/binary32/binary64 and x87 binary80. Finite values use up to 18
; significant digits in decorated fixed notation or 13 grouped digits in
; scientific notation. No CRT is involved; conversion is local x87 and integer
; work. Fixed integer groups use commas; fractional groups use spaces.

define win32.select.types system_console
define win32.select.downlevel kernel32

include 'common/policy.g'
include 'common/names.g'
include 'hexed.h'
include 'common/vt.g'

public forms_render

FORMS_COLS := LAYOUT_COLS - 1	; leave column 76 blank; avoid delayed wrap

≡	forms_integer_sizes db 1,2,4,8
≡	forms_float_sizes db 2,4,8,10
≡	forms_ten dq 10.0
≡	forms_one dq 1.0
≡	forms_scale13 dq 1000000000000
≡	forms_limit13 dq 10000000000000
≡	forms_scale18 dq 100000000000000000
≡	forms_limit18 dq 1000000000000000000
≡	forms_na db 'n/a'
≡	forms_nan db 'nan'
≡	forms_inf db 'inf'
≡	forms_ninf db '-inf'
≡	forms_zero db '0'
≡	forms_nzero db '-0'


; Paint has already positioned RDI at column 1 of the first panel row and set
; normal attributes. This routine emits exactly four lines and leaves the real
; cursor placement to paint's frame_end.
proc forms_render uses r12
	cmp	dword [rbx + HexState.panel_page], 2
	jz	.signed
	cmp	dword [rbx + HexState.panel_page], 3
	jz	.unsigned
	call	render_float_page
	ret
.signed:
	call	render_signed_page
	ret
.unsigned:
	call	render_unsigned_page
	ret
endp


; R10D is the row/type index. Each page keeps it live across the helpers.
render_float_page:
	xor	r10d, r10d
.row:
	call	emit_float_prefix		; R8D = logical prefix columns
	mov	r12d, r8d
	lea	rax, [forms_float_sizes]
	movzx	ecx, byte [rax + r10]
	call	format_float		; RSI text, EDX bytes, ECX columns
	mov	r9d, 12		; reserve the full-width uNN/sNN label columns
	mov	r8d, r12d
	call	emit_left_value
	call	emit_float_suffix
	call	emit_line_end
	inc	r10d
	cmp	r10d, HELP_ROWS
	jb	.row
	retn


render_signed_page:
	xor	r10d, r10d
.row:
	call	emit_signed_prefix	; R8D = logical prefix columns
	mov	r12d, r8d
	lea	rax, [forms_integer_sizes]
	movzx	ecx, byte [rax + r10]
	call	load_integer
	jc	.unavailable
	test	r10d, r10d
	jz	.s8
	cmp	r10d, 1
	jz	.s16
	cmp	r10d, 2
	jz	.s32
	jmp	.formatted		; qword is already in RAX
.s8:	movsx	rax, al
	jmp	.formatted
.s16:	movsx	rax, ax
	jmp	.formatted
.s32:	movsxd	rax, eax
.formatted:
	mov	r9d, 1
	call	format_integer
	jmp	.value
.unavailable:
	lea	rsi, [forms_na]
	mov	edx, 3
	mov	ecx, 3
.value:
	mov	r8d, r12d
	xor	r9d, r9d		; no suffix: signed field reaches column 76
	call	emit_aligned_value
	call	emit_line_end
	inc	r10d
	cmp	r10d, HELP_ROWS
	jb	.row
	retn


render_unsigned_page:
	xor	r10d, r10d
.row:
	call	emit_unsigned_prefix	; R8D = logical prefix columns
	mov	r12d, r8d
	lea	rax, [forms_integer_sizes]
	movzx	ecx, byte [rax + r10]
	call	load_integer
	jc	.unavailable
	xor	r9d, r9d
	call	format_integer
	jmp	.value
.unavailable:
	lea	rsi, [forms_na]
	mov	edx, 3
	mov	ecx, 3
.value:
	mov	r8d, r12d
	mov	r9d, 6		; s8 keeps the same field width as s16/s32/s64
	call	emit_aligned_value
	call	emit_unsigned_suffix
	call	emit_line_end
	inc	r10d
	cmp	r10d, HELP_ROWS
	jb	.row
	retn


; RSI/EDX/ECX describe value bytes/logical columns. R8D is prefix columns and
; R9D suffix columns. Pad so the suffix (or the signed value itself) ends at 75.
; Column 76 must remain untouched: printing there enables delayed auto-wrap, so
; the following ESC[K can wrap and erase the final character of the value.
emit_aligned_value:
	mov	eax, FORMS_COLS
	sub	eax, r8d
	sub	eax, ecx
	sub	eax, r9d
	jns	.pad
	xor	eax, eax		; defensive: formatters are intended to fit
.pad:	mov	ecx, eax
	mov	al, ' '
	rep	stosb
	mov	ecx, edx
	rep	movsb
	retn

; Float text starts immediately after f16/f32/f64/f80; only the remainder of
; its wide field is padded before the compact integer labels.
emit_left_value:
	mov	eax, FORMS_COLS
	sub	eax, r8d
	sub	eax, ecx
	sub	eax, r9d
	jns	.copy
	xor	eax, eax
.copy:
	mov	ecx, edx
	rep	movsb
	mov	ecx, eax
	mov	al, ' '
	rep	stosb
	retn


; Carry one line to the next without ever issuing LF from the bottom row.
emit_line_end:
	cmp	r10d, HELP_ROWS - 1
	jz	.last
	<| 27,'[K',27,'[1B',13 |>
	retn
.last:
	<| 27,'[K' |>
	retn


; Type-label layouts. U+2502 BOX DRAWINGS LIGHT VERTICAL is E2 94 82 in UTF-8.
emit_float_prefix:
	test	r10d, r10d
	jz	.r0
	cmp	r10d, 1
	jz	.r1
	cmp	r10d, 2
	jz	.r2
	<| 'f80 ' |>
	mov	r8d, 4
	retn
.r0:
	<| 'f16 ' |>
	mov	r8d, 4
	retn
.r1:
	<| 'f32 ' |>
	mov	r8d, 4
	retn
.r2:
	<| 'f64 ' |>
	mov	r8d, 4
	retn

emit_float_suffix:
	test	r10d, r10d
	jz	.r0
	cmp	r10d, 1
	jz	.r1
	cmp	r10d, 2
	jz	.r2
	<| ' ',226,148,130,' u64 ',226,148,130,' s64' |>
	retn
.r0:
	<| ' ',226,148,130,' u8  ',226,148,130,' s8' |>
	retn
.r1:
	<| ' ',226,148,130,' u16 ',226,148,130,' s16' |>
	retn
.r2:
	<| ' ',226,148,130,' u32 ',226,148,130,' s32' |>
	retn

emit_signed_prefix:
	test	r10d, r10d
	jz	.r0
	cmp	r10d, 1
	jz	.r1
	cmp	r10d, 2
	jz	.r2
	<| 'f80 ',226,148,130,' u64 ',226,148,130,' s64 ' |>
	mov	r8d, 16
	retn
.r0:
	<| 'f16 ',226,148,130,' u8  ',226,148,130,' s8 ' |>
	mov	r8d, 15
	retn
.r1:
	<| 'f32 ',226,148,130,' u16 ',226,148,130,' s16 ' |>
	mov	r8d, 16
	retn
.r2:
	<| 'f64 ',226,148,130,' u32 ',226,148,130,' s32 ' |>
	mov	r8d, 16
	retn

emit_unsigned_prefix:
	test	r10d, r10d
	jz	.r0
	cmp	r10d, 1
	jz	.r1
	cmp	r10d, 2
	jz	.r2
	<| 'f80 ',226,148,130,' u64 ' |>
	mov	r8d, 10
	retn
.r0:
	<| 'f16 ',226,148,130,' u8 ' |>
	mov	r8d, 9
	retn
.r1:
	<| 'f32 ',226,148,130,' u16 ' |>
	mov	r8d, 10
	retn
.r2:
	<| 'f64 ',226,148,130,' u32 ' |>
	mov	r8d, 10
	retn

emit_unsigned_suffix:
	test	r10d, r10d
	jz	.r0
	cmp	r10d, 1
	jz	.r1
	cmp	r10d, 2
	jz	.r2
	<| ' ',226,148,130,' s64' |>
	retn
.r0:
	<| ' ',226,148,130,' s8' |>
	retn
.r1:
	<| ' ',226,148,130,' s16' |>
	retn
.r2:
	<| ' ',226,148,130,' s32' |>
	retn


; ECX = byte width (1/2/4/8). RAX = zero-extended little-endian value, CF clear;
; CF set when the complete value is not present in the loaded view.
load_integer:
	mov	eax, [rbx + HexState.cur]
	add	eax, ecx
	cmp	eax, [rbx + HexState.view_bytes]
	ja	.no
	mov	rsi, [rbx + HexState.view]
	mov	eax, [rbx + HexState.cur]
	add	rsi, rax
	cmp	ecx, 1
	jz	.byte
	cmp	ecx, 2
	jz	.word
	cmp	ecx, 4
	jz	.dword
	mov	rax, [rsi]
	clc
	retn
.dword:
	mov	eax, [rsi]
	clc
	retn
.word:
	movzx	eax, word [rsi]
	clc
	retn
.byte:
	movzx	eax, byte [rsi]
	clc
	retn
.no:	stc
	retn


; RAX = value, R9D nonzero means signed. Returns comma-grouped ASCII in
; HexState.form_text as RSI/EDX bytes and ECX logical columns.
format_integer:
	lea	r11, [rbx + HexState.form_text + 96]
	xor	ecx, ecx		; digits since the last comma
	xor	esi, esi		; negative flag
	test	r9d, r9d
	jz	.magnitude
	test	rax, rax
	jns	.magnitude
	neg	rax			; INT64_MIN remains its unsigned magnitude
	mov	esi, 1
.magnitude:
	test	rax, rax
	jnz	.digit
	dec	r11
	mov	byte [r11], '0'
	jmp	.sign
.digit:
	cmp	ecx, 3
	jne	.divide
	dec	r11
	mov	byte [r11], ','
	xor	ecx, ecx
.divide:
	xor	edx, edx
	mov	r9, 10
	div	r9
	add	dl, '0'
	dec	r11
	mov	[r11], dl
	inc	ecx
	test	rax, rax
	jnz	.digit
.sign:
	test	esi, esi
	jz	.done
	dec	r11
	mov	byte [r11], '-'
.done:
	lea	rax, [rbx + HexState.form_text + 96]
	sub	rax, r11
	mov	edx, eax
	mov	ecx, eax
	mov	rsi, r11
	retn


; ECX = 2/4/8/10 bytes. Reads from the active byte and returns formatted UTF-8
; as RSI/EDX byte count and ECX display columns. The formatter temporarily uses
; x87 but empties its stack on every exit.
proc format_float
	locals
		size		dd ?
		negative	dd ?
		dec_exp		dd ?
		precision	dd ?
		last_digit	dd ?
		scientific	dd ?
		exp_negative	dd ?
		integer_digits	dd ?
		raw32		dd ?
		old_cw		dw ?
		work_cw		dw ?
		scaled		dq ?
		value		db 10 dup ?
		digitbuf	db 18 dup ?
		expbuf		db 6 dup ?
	endl
	mov	[size], ecx
	mov	dword [negative], 0
	mov	dword [scientific], 0
	mov	dword [exp_negative], 0

	; The complete representation must be in the current loaded view.
	mov	eax, [rbx + HexState.cur]
	add	eax, ecx
	cmp	eax, [rbx + HexState.view_bytes]
	ja	.unavailable
	mov	rsi, [rbx + HexState.view]
	mov	eax, [rbx + HexState.cur]
	add	rsi, rax

	cmp	dword [size], 2
	jz	.half
	cmp	dword [size], 4
	jz	.single
	cmp	dword [size], 8
	jz	.double
	jmp	.extended

.half:
	movzx	eax, word [rsi]
	mov	edx, eax
	shr	edx, 15
	mov	[negative], edx
	and	eax, 0x7FFF
	jz	.zero
	mov	r8d, eax
	shr	r8d, 10
	cmp	r8d, 31
	jz	.half_special
	and	eax, 0x3FF
	test	r8d, r8d
	jz	.half_subnormal
	add	r8d, 112		; half bias 15 -> binary32 bias 127
	shl	r8d, 23
	shl	eax, 13
	or	eax, r8d
	jmp	.half_sign
.half_subnormal:
	mov	ecx, -14
.half_normalize:
	test	eax, 0x400
	jnz	.half_sub_ready
	shl	eax, 1
	dec	ecx
	jmp	.half_normalize
.half_sub_ready:
	and	eax, 0x3FF
	shl	eax, 13
	add	ecx, 127
	shl	ecx, 23
	or	eax, ecx
.half_sign:
	cmp	dword [negative], 0
	jz	.half_load
	bts	eax, 31
.half_load:
	mov	[raw32], eax
	fld	dword [raw32]
	jmp	.loaded
.half_special:
	test	eax, 0x3FF
	jnz	.nan
	jmp	.infinity

.single:
	mov	eax, [rsi]
	mov	edx, eax
	shr	edx, 31
	mov	[negative], edx
	mov	r8d, eax
	and	r8d, 0x7FFFFFFF
	jz	.zero
	mov	edx, eax
	and	edx, 0x7F800000
	cmp	edx, 0x7F800000
	jne	.single_load
	test	eax, 0x007FFFFF
	jnz	.nan
	jmp	.infinity
.single_load:
	fld	dword [rsi]
	jmp	.loaded

.double:
	mov	rax, [rsi]
	mov	rdx, rax
	shr	rdx, 63
	mov	[negative], edx
	btr	rax, 63
	test	rax, rax
	jz	.zero
	mov	rdx, rax
	shr	rdx, 52
	cmp	edx, 0x7FF
	jne	.double_load
	shl	rax, 12
	test	rax, rax
	jnz	.nan
	jmp	.infinity
.double_load:
	fld	qword [rsi]
	jmp	.loaded

.extended:
	movzx	eax, word [rsi + 8]
	mov	edx, eax
	shr	edx, 15
	mov	[negative], edx
	and	eax, 0x7FFF
	mov	r8, [rsi]
	mov	edx, eax
	or	rdx, r8
	jz	.zero
	cmp	eax, 0x7FFF
	jne	.extended_finite
	mov	rax, 0x8000000000000000
	cmp	r8, rax
	jne	.nan
	jmp	.infinity
.extended_finite:
	; Nonzero exponents require the explicit integer bit. Treat unsupported
	; unnormal encodings as NaN rather than raising an x87 invalid exception.
	test	eax, eax
	jz	.extended_load
	bt	r8, 63
	jnc	.nan
.extended_load:
	fld	tword [rsi]

.loaded:
	; Windows commonly starts x87 in 53-bit precision. Preserve the caller's
	; control word but use 64-bit significands and round-to-nearest here; without
	; this, scaling an exact f32 by 10^17 loses the final decimal digits.
	fnstcw	[old_cw]
	mov	ax, [old_cw]
	and	ax, 0xF3FF		; RC = nearest
	or	ax, 0x0300		; PC = extended (64-bit significand)
	mov	[work_cw], ax
	fldcw	[work_cw]
	fstp	tword [value]
	fld	tword [value]
	fabs
	mov	dword [dec_exp], 0

	; Normalize ST0 to [1,10). The worst binary80 value takes fewer than five
	; thousand iterations, still cheap beside terminal I/O and free of tables.
.scale_down:
	fcom	qword [forms_ten]
	fnstsw	ax
	sahf
	jb	.scale_up
	fdiv	qword [forms_ten]
	inc	dword [dec_exp]
	jmp	.scale_down
.scale_up:
	fcom	qword [forms_one]
	fnstsw	ax
	sahf
	jae	.normalized
	fmul	qword [forms_ten]
	dec	dword [dec_exp]
	jmp	.scale_up

.normalized:
	mov	eax, [dec_exp]
	cmp	eax, -4
	jl	.use_scientific
	cmp	eax, 18
	jl	.use_fixed
.use_scientific:
	mov	dword [scientific], 1
	mov	dword [precision], 13
	fild	qword [forms_scale13]
	fmulp	st1, st0
	fistp	qword [scaled]
	mov	rax, [scaled]
	cmp	rax, [forms_limit13]
	jne	.have_scaled
	mov	r8, 10
	xor	edx, edx
	div	r8
	mov	[scaled], rax
	inc	dword [dec_exp]
	jmp	.have_scaled
.use_fixed:
	mov	dword [precision], 18
	fild	qword [forms_scale18]
	fmulp	st1, st0
	fistp	qword [scaled]
	mov	rax, [scaled]
	cmp	rax, [forms_limit18]
	jne	.have_scaled
	mov	r8, 10
	xor	edx, edx
	div	r8
	mov	[scaled], rax
	inc	dword [dec_exp]
	cmp	dword [dec_exp], 18
	jne	.have_scaled
	; Rounding 9.99...e17 into 1e18 crosses the notation boundary.
	mov	dword [scientific], 1
	mov	dword [precision], 13
	mov	r8, 100000
	xor	edx, edx
	div	r8
	mov	[scaled], rax

.have_scaled:
	; Produce exactly PRECISION digits backwards, then trim fractional zeroes.
	mov	ecx, [precision]
	lea	r8, [digitbuf + rcx]
	mov	rax, [scaled]
.make_digit:
	xor	edx, edx
	mov	r9, 10
	div	r9
	add	dl, '0'
	dec	r8
	mov	[r8], dl
	dec	ecx
	jnz	.make_digit
	mov	ecx, [precision]
.trim:
	cmp	ecx, 1
	jbe	.trimmed
	cmp	byte [digitbuf + rcx - 1], '0'
	jne	.trimmed
	dec	ecx
	jmp	.trim
.trimmed:
	mov	[last_digit], ecx

	lea	r11, [rbx + HexState.form_text]
	mov	r8, r11		; start for byte-count calculation
	cmp	dword [negative], 0
	jz	.not_negative
	mov	byte [r11], '-'
	inc	r11
.not_negative:
	cmp	dword [scientific], 0
	jnz	.emit_scientific

	mov	eax, [dec_exp]
	test	eax, eax
	js	.emit_small_fixed
	inc	eax			; digits before the decimal point
	mov	[integer_digits], eax
	; The first integer group may contain one, two, or three digits. R9D counts
	; down to each comma boundary while ECX indexes the significant digits.
	xor	edx, edx
	mov	ecx, 3
	div	ecx
	test	edx, edx
	jnz	.have_integer_group
	mov	edx, 3
.have_integer_group:
	mov	r9d, edx
	xor	ecx, ecx
.fixed_integer:
	mov	al, [digitbuf + rcx]
	mov	[r11], al
	inc	r11
	inc	ecx
	dec	r9d
	cmp	ecx, [integer_digits]
	jae	.fixed_integer_done
	test	r9d, r9d
	jnz	.fixed_integer
	mov	byte [r11], ','
	inc	r11
	mov	r9d, 3
	jmp	.fixed_integer
.fixed_integer_done:
	mov	edx, [integer_digits]
	cmp	edx, [last_digit]
	jnc	.finish
	mov	byte [r11], '.'
	inc	r11
	xor	r9d, r9d		; fractional digits in the current group
.fixed_fraction:
	mov	al, [digitbuf + rdx]
	mov	[r11], al
	inc	r11
	inc	edx
	inc	r9d
	cmp	edx, [last_digit]
	jae	.finish
	cmp	r9d, 3
	jb	.fixed_fraction
	mov	byte [r11], ' '
	inc	r11
	xor	r9d, r9d
	jmp	.fixed_fraction

.emit_small_fixed:
	mov	word [r11], '0.'
	add	r11, 2
	neg	eax
	dec	eax			; leading fractional zeroes before digitbuf
	mov	edx, eax
	xor	ecx, ecx
	xor	r9d, r9d		; group from the decimal point, zeroes included
.small_next:
	test	edx, edx
	jz	.small_digit
	mov	al, '0'
	dec	edx
	jmp	.small_emit
.small_digit:
	mov	al, [digitbuf + rcx]
	inc	ecx
.small_emit:
	mov	[r11], al
	inc	r11
	inc	r9d
	test	edx, edx
	jnz	.small_more
	cmp	ecx, [last_digit]
	jae	.finish
.small_more:
	cmp	r9d, 3
	jb	.small_next
	mov	byte [r11], ' '
	inc	r11
	xor	r9d, r9d
	jmp	.small_next

.emit_scientific:
	mov	al, [digitbuf]
	mov	[r11], al
	inc	r11
	cmp	dword [last_digit], 1
	jbe	.scientific_suffix
	mov	byte [r11], '.'
	inc	r11
	mov	ecx, 1
	xor	edx, edx		; digits in the current group
.scientific_digits:
	mov	al, [digitbuf + rcx]
	mov	[r11], al
	inc	r11
	inc	ecx
	inc	edx
	cmp	ecx, [last_digit]
	jae	.scientific_suffix
	cmp	edx, 3
	jne	.scientific_digits
	mov	byte [r11], ' '
	inc	r11
	xor	edx, edx
	jmp	.scientific_digits
.scientific_suffix:
	; " × 10^"; multiplication sign U+00D7 is C3 97.
	mov	byte [r11], ' '
	mov	word [r11 + 1], 0x97C3
	mov	dword [r11 + 3], ' 10^'
	add	r11, 7
	mov	eax, [dec_exp]
	test	eax, eax
	jns	.exponent_magnitude
	neg	eax
	mov	dword [exp_negative], 1
	; Unicode minus U+2212 is E2 88 92.
	mov	word [r11], 0x88E2
	mov	byte [r11 + 2], 0x92
	add	r11, 3
.exponent_magnitude:
	lea	r9, [expbuf + 6]
	xor	ecx, ecx
.exponent_digit:
	xor	edx, edx
	mov	rsi, 10
	div	rsi
	add	dl, '0'
	dec	r9
	mov	[r9], dl
	inc	ecx
	test	eax, eax
	jnz	.exponent_digit
.copy_exponent:
	mov	al, [r9]
	mov	[r11], al
	inc	r9
	inc	r11
	dec	ecx
	jnz	.copy_exponent

.finish:
	mov	rdx, r11
	sub	rdx, r8
	mov	ecx, edx
	cmp	dword [scientific], 0
	jz	.return_scratch
	dec	ecx			; U+00D7 occupies two bytes, one column
	cmp	dword [exp_negative], 0
	jz	.return_scratch
	sub	ecx, 2		; U+2212 occupies three bytes, one column
.return_scratch:
	fldcw	[old_cw]
	lea	rsi, [rbx + HexState.form_text]
	ret

.unavailable:
	lea	rsi, [forms_na]
	mov	edx, 3
	mov	ecx, 3
	ret
.nan:
	lea	rsi, [forms_nan]
	mov	edx, 3
	mov	ecx, 3
	ret
.infinity:
	cmp	dword [negative], 0
	jnz	.negative_infinity
	lea	rsi, [forms_inf]
	mov	edx, 3
	mov	ecx, 3
	ret
.negative_infinity:
	lea	rsi, [forms_ninf]
	mov	edx, 4
	mov	ecx, 4
	ret
.zero:
	cmp	dword [negative], 0
	jnz	.negative_zero
	lea	rsi, [forms_zero]
	mov	edx, 1
	mov	ecx, 1
	ret
.negative_zero:
	lea	rsi, [forms_nzero]
	mov	edx, 2
	mov	ecx, 2
	ret
endp
