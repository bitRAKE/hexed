; Late-processing data groups, for MS64 NEWCOFF and the fasm2_calm projection.
; Taken from ../../controls/common/data_blocks.g, which derived it from
; fasm2/examples/conio/data_blocks.inc.
;
; Three gatherers, prefixed at the point of declaration:
;
;       ≡ table  dw 1,2,3,4           ; CONST, read-only non-string data
;       ∵ .count dd 1                 ; DATA, initialized, mutable
;       □ hex    HexState             ; BSS, uninitialized
;
; A prefixed line is stashed rather than emitted. Every stashed line is emitted
; at postpone time, grouped by block, so a declaration can sit beside the code
; that uses it while the object still gets three clean sections.
;
; The gatherers are namespace aware. A stashed line is held as a symbolic value,
; and symbols in a symbolic value carry their context, so a declaration written
; inside a procedure still binds there when it is finally emitted.
;
; INCLUDE ORDER
;
;   include 'generated/fasm2_calm/x64/windows.inc'   ; brings macro/struct.inc
;   include 'common/data_blocks.g'
;
; struct.inc supplies mvmacro. Including after windows.inc also puts this
; postpone block after the projection's finalizer, so imports are emitted first
; and these sections close cleanly behind them.

if ~ definite HEXED_DATA_BLOCKS_INCLUDED
HEXED_DATA_BLOCKS_INCLUDED := 1

; Pooled, deduplicated byte-string literals. The VT fragment notation in vt.g
; is the heaviest user: a paint routine names no strings, it writes escape
; sequences inline, and identical fragments — there are many — collapse to one
; copy. Named, null-terminated messages use the same pool.
include 'macro/globstr.inc'
GLOBSTR.reuse := 1

iterate block,\
	≡,\	; CONST, read-only data
	∵,\	; DATA, initialized data
	□	; BSS, uninitialized data

	define block block
	namespace block
		define GATHER
		calminstruction item line& ; namespace aware
			match ,line
			jyes ⌽
			take GATHER,line
			exit

		⌽:	take line,GATHER
			jyes ⌽
		out:	assemble line
			take ,line
			take line,line
			jyes out
			arrange line,=block=.=end:
			assemble line
			arrange GATHER,=err 'block expressed'
		end calminstruction
		restore GATHER
	end namespace
	mvmacro block,block.item

	block align 64		; cache line separation
	block block.start:
end iterate

postpone

; Read-only: pooled strings first, then gathered non-string constants.
	section '.rdata$c' data readable align 64
	HEXED_CONST_BASE:
	GLOBSTR.here
	≡

	if ∵.end - ∵.start
		section '.data' data readable writeable align 64
	end if
	∵

; This is NEWCOFF's intended BSS declaration:
;
;       section '.bss' readable writeable align 64
;
; There is no `udata` attribute.  When the section has logical size but emitted
; no bytes, newcoffms.inc derives IMAGE_SCN_CNT_UNINITIALIZED_DATA and sets
; PointerToRawData to zero.  The section must contain only uninitialized
; declarations: an initialized prefix followed by reserved space is instead
; padded with real zeros.
;
; BSS therefore needs a separate section.  In a COFF object, VirtualSize is
; reserved and must be zero, so it cannot describe a logical extent larger than
; the initialized raw data as it can in a PE image.  The all-uninitialized
; section and its zero PointerToRawData are the object format's representation.
;
; The `data` attribute is deliberately absent, and its absence is load-bearing.
; `data` sets IMAGE_SCN_CNT_INITIALIZED_DATA (newcoffms.inc ~455); the
; finalizer then *adds* IMAGE_SCN_CNT_UNINITIALIZED_DATA and sets
; PointerToRawData to zero (~366) without clearing the first flag. The MS
; linker believes INITIALIZED_DATA, reads 204 bytes from file offset 0 — the
; object's own header and section table — and maps them where the program
; expects zeroed state. It does not fault; it starts up holding whatever those
; bytes say, which is as quiet a failure as this file can produce.
;
; `readable writeable` alone is the intended usage and leaves the finalizer to
; derive the one correct flag. Worth fixing upstream so `data` is not a trap
; here. The sibling controls/common/data_blocks.g carries the same line and has
; never had anything in □ to expose it.
	if □.end - □.start
		section '.bss' readable writeable align 64
	end if
	□

	repeat 1,\
		I:≡.end - HEXED_CONST_BASE,\
		J:∵.end - ∵.start,\
		K:□.end - □.start

		display 10,9,`I,' CONST bytes',\
			10,9,`J,' DATA bytes',\
			10,9,`K,' BSS bytes'
	end repeat
end postpone

end if
