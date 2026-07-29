; The view: the file window that is on screen, and the only region anything
; here can read or write.
;
; `view` is what is displayed and edited. `orig` is what the file holds for the
; same range. The set of pending changes is the difference between them — not a
; flag array that could disagree with either, and not a shadow document that
; could carry an edit somewhere the user cannot see.
;
; Three properties follow, and they are the point of the design:
;
;   * A commit writes [chg_lo, chg_hi] at view_off. Both ends are indices into
;     the view, so a write cannot reach a byte the user was not looking at. The
;     bound is structural, not a check that could be forgotten.
;
;   * A restore is a copy of orig over view. Nothing is read from the file, so
;     a restore cannot fail or half-succeed.
;
;   * view_load re-reads from the file unconditionally. That is safe only
;     because navigation cannot proceed while the difference is non-empty — the
;     prompt in hexed.asm stands in the way — so there is never an unwritten
;     byte for a reload to discard. This is the invariant the whole program
;     rests on.
;
; The file is never grown or shortened. A hex editor that edits in place has no
; insert and no delete, which is also why ReadFile/WriteFile is the right tool
; and a mapped view is not: a mapping decides for itself when to write back,
; and this program's entire contract is that only F2 does.

define win32.select.types system_console
define win32.select.downlevel kernel32

include 'common/policy.g'
include 'common/names.g'
include 'hexed.h'
include 'common/vt.g'	; after the structures; see the note in policy.g

; Exposed interface.
public view_clamped
public view_load
public view_clamp_cursor
public view_rescan
public view_commit
public view_restore

extrn hex

□	io_count	dd ?


; RAX = candidate offset -> RAX = the offset the view will actually use:
; BPR-aligned, non-negative, and never past the last page. Shared with the
; navigation code so a request that would not move the view can be recognised
; before it becomes a question for the user.
proc view_clamped uses rbx
	lea	rbx, [hex]
	and	rax, -BPR
	jns	.positive
	xor	eax, eax
.positive:
	mov	rcx, [rbx + HexState.file_size]
	add	rcx, BPR-1
	and	rcx, -BPR		; the last row, even if partial
	mov	edx, [rbx + HexState.view_cap]
	sub	rcx, rdx
	jns	.have_last
	xor	ecx, ecx		; the file is shorter than one view
.have_last:
	cmp	rax, rcx
	jbe	.done
	mov	rax, rcx
.done:	ret
endp


; Fill the view from the file at view_off and take orig with it. Always safe to
; call: nothing unwritten can be in flight here.
proc view_load uses rbx rsi rdi
	lea	rbx, [hex]
	mov	rax, [rbx + HexState.view_off]
	call	view_clamped
	mov	[rbx + HexState.view_off], rax

	SetFilePointerEx [rbx + HexState.hFile], [rbx + HexState.view_off], 0,\
		FILE_BEGIN
	mov	dword [io_count], 0
	mov	r8d, [rbx + HexState.view_cap]
	ReadFile [rbx + HexState.hFile], [rbx + HexState.view], r8, &io_count, 0
	test	eax, eax		; BOOL
	jnz	.read
	mov	dword [io_count], 0
.read:	mov	eax, [io_count]
	mov	[rbx + HexState.view_bytes], eax

	; The whole buffer is copied, not just the valid part, so the bytes past
	; end of file compare equal and can never be reported as changes.
	mov	rsi, [rbx + HexState.view]
	mov	rdi, [rbx + HexState.orig]
	mov	ecx, [rbx + HexState.view_cap]
	shr	ecx, 3			; view_cap is a multiple of BPR
	rep	movsq

	mov	dword [rbx + HexState.chg_lo], -1
	mov	dword [rbx + HexState.chg_hi], -1
	call	view_clamp_cursor
	ret
endp


; Keep the cursor on a byte that exists. Called after every reload, because a
; shorter view — end of file, or a smaller window — can leave it past the end.
proc view_clamp_cursor uses rbx
	lea	rbx, [hex]
	mov	eax, [rbx + HexState.cur]
	mov	ecx, [rbx + HexState.view_bytes]
	test	ecx, ecx
	jz	.empty
	dec	ecx
	cmp	eax, ecx
	jbe	.store
	mov	eax, ecx
	jmp	.store
.empty:	xor	eax, eax
.store:	mov	[rbx + HexState.cur], eax
	mov	dword [rbx + HexState.nibble], 0
	ret
endp


; Recompute the pending change set. Called after every edit; a scan of one
; screenful per keystroke costs nothing and means an edit that puts a byte back
; the way it was clears the pending state, as it should.
proc view_rescan uses rbx rsi rdi
	lea	rbx, [hex]
	mov	dword [rbx + HexState.chg_lo], -1
	mov	dword [rbx + HexState.chg_hi], -1
	mov	ecx, [rbx + HexState.view_bytes]
	test	ecx, ecx
	jz	.done
	mov	rsi, [rbx + HexState.view]
	mov	rdi, [rbx + HexState.orig]
	xor	eax, eax
.scan:	mov	dl, [rsi + rax]
	cmp	dl, [rdi + rax]
	jz	.same
	cmp	dword [rbx + HexState.chg_lo], 0
	jns	.high
	mov	[rbx + HexState.chg_lo], eax
.high:	mov	[rbx + HexState.chg_hi], eax
.same:	inc	eax
	cmp	eax, ecx
	jc	.scan
.done:	ret
endp


; Write the pending changes and nothing else. EAX = 1 when the view and the
; file agree afterwards.
;
; The write covers [chg_lo, chg_hi] only. Bytes the user did not touch are not
; rewritten with their own values, so the file's timestamp is the only thing
; that moves for the rest of the view — and nothing at all outside it.
proc view_commit uses rbx rsi rdi
	locals
		pos	dq ?
	endl
	lea	rbx, [hex]
	cmp	dword [rbx + HexState.chg_lo], 0
	js	.clean
	cmp	dword [rbx + HexState.readonly], 0
	jnz	.readonly

	mov	eax, [rbx + HexState.chg_lo]
	mov	rcx, [rbx + HexState.view_off]
	add	rcx, rax
	mov	[pos], rcx
	SetFilePointerEx [rbx + HexState.hFile], [pos], 0, FILE_BEGIN
	test	eax, eax		; BOOL
	jz	.failed

	mov	rdx, [rbx + HexState.view]
	mov	ecx, [rbx + HexState.chg_lo]
	add	rdx, rcx
	mov	r8d, [rbx + HexState.chg_hi]
	sub	r8d, ecx
	inc	r8d
	WriteFile [rbx + HexState.hFile], rdx, r8, &io_count, 0
	test	eax, eax		; BOOL
	jz	.failed
	FlushFileBuffers [rbx + HexState.hFile]

	; Counted before the span is cleared, for the line printed on exit.
	mov	ecx, [rbx + HexState.chg_hi]
	sub	ecx, [rbx + HexState.chg_lo]
	inc	ecx
	add	[rbx + HexState.written], rcx

	; The file now says what the view says.
	mov	rsi, [rbx + HexState.view]
	mov	rdi, [rbx + HexState.orig]
	mov	ecx, [rbx + HexState.view_cap]
	shr	ecx, 3			; view_cap is a multiple of BPR
	rep	movsq
	mov	dword [rbx + HexState.chg_lo], -1
	mov	dword [rbx + HexState.chg_hi], -1

.m_written GLOBSTR 'written',0
	lea	rax, [.m_written]
	mov	[rbx + HexState.msg], rax
	mov	eax, 1
	ret

.clean:
.m_clean GLOBSTR 'nothing to write',0
	lea	rax, [.m_clean]
	mov	[rbx + HexState.msg], rax
	mov	eax, 1
	ret

.readonly:
.m_ro GLOBSTR 'read-only: opened without write access',0
	lea	rax, [.m_ro]
	mov	[rbx + HexState.msg], rax
	xor	eax, eax
	ret

.failed:
.m_failed GLOBSTR 'write failed',0
	lea	rax, [.m_failed]
	mov	[rbx + HexState.msg], rax
	xor	eax, eax
	ret
endp


; Put the view back the way the file has it. No I/O, so this cannot fail.
proc view_restore uses rbx rsi rdi
	lea	rbx, [hex]
	mov	rsi, [rbx + HexState.orig]
	mov	rdi, [rbx + HexState.view]
	mov	ecx, [rbx + HexState.view_cap]
	shr	ecx, 3			; view_cap is a multiple of BPR
	rep	movsq
	mov	dword [rbx + HexState.chg_lo], -1
	mov	dword [rbx + HexState.chg_hi], -1
.m_restored GLOBSTR 'restored',0
	lea	rax, [.m_restored]
	mov	[rbx + HexState.msg], rax
	mov	eax, 1
	ret
endp
