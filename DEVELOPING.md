# Developing hexed

This document covers the build, implementation contracts, binary-format
requirements, and verification history. See [README.md](README.md) for usage.

## Build

This is the low fixed-base port of [bitRAKE/hexed](https://github.com/bitRAKE/hexed),
built on this repository's PSDK projection. The trajectory is unchanged:

```text
fasmg -> MS64 NEWCOFF bigobj -> link -> PE64
```

The resulting executable imports `kernel32`, and `user32` for placing its window
(see Geometry and console lifetime). `preamble.inc` selects full `NEWCOFF.DEBUG=6`, so
the link also writes `hexed.pdb`. From the repository root:

```bat
examples\_build.cmd hexed
```

The script assembles every `.asm` in this folder and links `hexed.exe` from the
response file that [`hexed.asm`](hexed.asm) writes. That file names the other
objects and libraries beside the code that depends on them: `program` gives the
entry point, subsystem and load configuration, and `response` adds the rest.

`namespace.inc` publishes editor-only project metadata under `__EDITOR__`:
`build.preamble = 'preamble.inc'` selects the shared language environment,
`project.modules.1` through `.4` order view, paint, data forms, then the program
object, and `build.hexed.steps.1` names `link @hexed.response`. Every module also
includes `namespace.inc`, which includes the guarded preamble for native builds.

The selected preamble contains lowbase and CodeView/PROC/unwind policy. SDK
headers remain module-specific. Full debug checksums are retained: CALM hashing
and per-assembly checksum reuse remove repeated interpreted hashing. See the
[measured performance comparison](../../projects/editor/docs/hexed-performance.md)
for the native/editor timings and the SDK-union configuration that was rejected.

For inspection, LLVM's tools read the image:

```bat
llvm-readobj --file-headers --coff-imports --coff-load-config hexed.exe
llvm-readobj --unwind hexed.exe
llvm-objdump -d hexed.exe
```

## Repository layout

```text
examples\hexed\
  README.md             user documentation
  DEVELOPING.md         this document
  roadmap.md            features that need more thought
  namespace.inc         project manifest and native preamble entry
  preamble.inc          shared lowbase/CodeView/PROC/unwind policy
  hexed.h               geometry, HexState, and cross-object contracts
  vt.inc                pooled `<| ... |>` output-fragment notation
  hexed.asm             entry, console lifetime, event loop, input and response
  view.asm              view load, commit, restore, rescan, and clamp
  paint.asm             VT composition and rendering
  data_forms.asm        active-byte float/signed/unsigned interpretation
```

What the port replaced:

- **`common/policy.g`** became `namespace.inc` over `include\lowbase.inc`, which
  supplies the prelude, NEWCOFF, the data anchors, PROC/ENDP with the low-base
  fastcall, and the string pools.
  - fasm2's NEWCOFF format no longer needs the `format MS64 NEWCOFF` shim.
  - `newcoff_debug_prologue` now forwards `<reglist>` grouped, so the
    `hexed_debug_prologue` shim is gone too.
- **`common/names.g` is gone.** The PSDK projection already spells every value
  as the SDK does (`ENABLE_VIRTUAL_TERMINAL_PROCESSING`, `VK_F1`), so no short
  aliases are needed.
- **Each module includes the SDK headers it uses**, after `namespace.inc` and in
  one order:
  - the base types (`minwindef`, `windef`, `winnt`);
  - kernel32 by subject: console, files and handles, memory, process,
    synchronization, text, and the `WinBase` catch-all last;
  - then user32.

  `hexed.asm` needs 17, `view.asm` two, `paint.asm` one, and `data_forms.asm`
  none.
- **`common/data_blocks.g` became the anchors of `include\macro\anchor.inc`.**
  `≡`/`∵`/`□` lines are `CONST.n`/`DATA.n`/`BSS.n` lines, placed by
  alignment. The GLOBSTR pool lives in CONST.
- **`common/vt.g` is `vt.inc`.** A fragment's address is `mov esi,fragment`:
  5 bytes and an ADDR32 relocation.
- **Direct image addresses are 32-bit immediates** everywhere a label alone
  was loaded (`mov ebx,hex`, `mov esi,.m_usage`, `mov eax,forms_na`).
  Register-formed addresses keep `lea`.

## State and edit invariants

The visible view is the complete editable surface. Three rules enforce that:

1. Typing writes `view[cur]`, and `cur` is clamped to
   `[0, view_bytes)`.
2. `view_rescan` compares `view` with `orig` after every edit and records the
   first and last differing byte.
3. Every change of `view_off` passes through `nav_request`. It permits an
   overlapping destination only when the complete absolute change span remains
   visible; otherwise it defers the request behind the prompt.

`view_commit` writes the smallest continuous span containing every difference:

```text
view_off + chg_lo .. view_off + chg_hi
```

Unchanged bytes between separated edits may be rewritten with their existing
values. Nothing before `chg_lo`, after `chg_hi`, or outside the current view is
touched. The write is followed by `FlushFileBuffers`.

Clean navigation uses `view_load` directly. Overlapping navigation with pending
changes uses `view_retain`: the changed span is copied into the empty output
buffer, the destination view and baseline are reloaded, and the span is
reapplied at its new index before `view_rescan`. No shadow document or dirty
bitmap is needed.

Resize follows the same containment rule, but cannot use arena-local scratch
because `arena_fit` may replace the arena. It saves the changed span in a
temporary allocation, applies geometry, reloads, reapplies, and frees the
temporary block. The span is checked again against `arena_fit`'s actual
geometry, including its allocation-failure fallback. A resize that would
exclude any changed byte remains a forced prompt.

Ctrl and Alt chords are rejected by the data-entry path. The character pane
accepts only printable ASCII; the hexadecimal pane provides the full byte range.

## Application-thread register contract

The entry point never returns, and ordinary internal work remains on one thread:

```text
RBX = &hex, for the process lifetime
RBP = &irec, for the event loop lifetime
RDI = next byte in the output buffer
RSI = source and scan cursor
```

Internal procedures do not save registers already owned by the application
thread. Win64 preserves the nonvolatile set across API calls.

`ConsoleCtrlHandler` is the exception. Windows may invoke it on another thread
with unrelated register contents, so it uses the absolute `hex` object and none
of the application-thread register state.

Procedures that execute an ABI call have an aligned static-RSP frame. Output
builders call only private leaves and require no ABI call frame. The `emit_*`
leaves have no frame or unwindable state.

## Output architecture

### One event, one write

Painting routines append to a shared buffer through `RDI` and return without
writing. The event loop drains `[obuf,RDI)` once after a completed input event
and resets `RDI` to `obuf`.

`vt_resize` is the sole mid-event drain. Its XTWINOPS request must reach the
terminal before the legacy resize fallback and size readback execute.

The output region is sized as:

```text
viewrows * OBUF_PER_ROW + OBUF_SLACK
```

`OBUF_PER_ROW` covers the pathological per-row rendering cost; the slack covers
the ruler, footer, four panel lines, prompts, setup, and teardown. A normal event
composes at most one complete frame between drains.

### Damage-sized painters

| Entry point | Work | Used for |
| --- | --- | --- |
| `paint_cells` | two byte cells and the footer | cursor movement and typing |
| `paint_scroll` | one `SU`/`SD`, exposed rows, two cells | short scrolling |
| `paint_rows` | an inclusive row range and footer | write or restore |
| `paint_status` | footer and open four-line panel | pane/panel changes, Ctrl+G entry |
| `paint_full` | complete screen | resize, page movement, goto, code page |

Scrolling uses `DECSTBM` over only the data rows. The terminal moves the address
column with its data, and only newly exposed rows are rendered. Scrolling also
moves the highlighted cursor cell; repainting `cur - delta*BPR` and `cur`
removes the stale highlight and draws the new one.

`emit_attr` tracks the active SGR class and emits only when the class changes.
Every emitted class begins from SGR 0, so classes do not depend on an unwind
order. The terminal's real cursor is parked on the selected nibble or character
at frame end.

The 76-column ruler is erased before its text is written. Its final `F` occupies
the terminal's last column; erasing afterward would include that cell while the
terminal still holds a delayed-wrap cursor there. The following absolute cursor
move cancels delayed wrap safely.

### Footer, persistent panels, and exit summary

The footer is reverse-video across the complete logical width. It is padded
explicitly because `ESC[K` erases using colours, while reverse video is an
attribute and would end with the text.

The normal footer contains only file name, total byte count, code page, and the
`Tab pane` / `F1 help` hints, then the offset field. While `panel` is nonzero, geometry reserves four
bottom rows and moves the footer above them. `render_panel` draws help locally
or delegates data forms to `forms_render` in `data_forms.asm`; every
damage-sized repaint therefore refreshes an open panel. F1 advances help and F4
rotates float/signed/unsigned forms. The panels are mutually exclusive and
switch without another geometry change. An Escape release closes either panel
from every page and remains recorded as the first half of the existing
release-driven `Esc Esc` exit gesture. Prompt cancellation takes priority.

`data_forms.asm` reads little-endian values only when their complete
representation remains in the loaded view. Integer conversion handles the full
signed/unsigned 64-bit range and inserts comma groups. Float conversion handles
binary16, binary32, binary64, and the 10-byte x87 binary80 encoding without a
CRT dependency. It temporarily selects the x87 64-bit significand and
round-to-nearest modes, restores the caller's control word, and emits compact
fixed or scientific decimal plus signed zero, infinity, NaN, and `n/a`. Fixed
integer groups use commas and fractional groups use spaces; scientific
significands use the same three-digit fractional spacing.

The offset field takes the footer's last `GOTO_CHARS + 2` columns, from
`FIELD_COL0`, whenever the window is at least `LAYOUT_COLS` wide. The text
before it is padded to `FIELD_COL0 - 1` first. The field shows the cursor's
offset: `0x` and eight digits, or decimal right-aligned in ten columns.

The address column has nine columns, and decimal in it is right-aligned and
truncating: `emit_dec_field` keeps the low nine digits of a ten-digit offset.
The field therefore carries the whole offset.

Ctrl+G turns the field into an entry line. `HexState.goto` routes every key to
`.goto_key` while it is set:
- printable keys append to `goto_text`, up to `GOTO_CHARS` of `0-9 a-f $ h x`;
- Backspace removes one;
- Enter calls `parse_goto`.

Hex mode starts the text as `0x`, decimal mode empty. `parse_goto` reads `$`
or `0x` before the digits, or `h` after them, as hexadecimal; anything else is
decimal. Hex digits without one of those markers are not an offset, and
neither is an empty entry. `parse_goto` returns CF for those, and the line
stays open. Ten characters cannot overflow 64 bits in either radix.

A target already in the view only moves the cursor. Any other target goes
through `nav_request NAV_GOTO`, with the target's row centred. `goto_target`
and `goto_pending` carry the byte to `nav_perform`, which puts the cursor on
it once the view has loaded. The pending-changes prompt's cancel clears
`goto_pending`.

An Escape release closes the line and clears `last_up_vk`, so the same
release is not the first half of `Esc Esc`. While the line is open,
`frame_end` parks the caret after its text.

`data_forms.asm` builds its row labels from tables. Each emitter is a
`rep movsb` from a `BLOCK CONST.4` table, indexed by R10D. The table is laid
out as the panel shows it, one `db` per screen row:

```asm
BLOCK CONST.4
	.table	db 'f16 │ u8  │ s8  '
		db 'f32 │ u16 │ s16 '
		db 'f64 │ u32 │ s32 '
		db 'f80 │ u64 │ s64 '
	label_rows .table, .bytes, .columns
END BLOCK
```

`label_rows` reads the rows back and defines two constants:
- `.bytes`, the row length in bytes;
- `.columns`, the columns a row takes on screen. A UTF-8 sequence is one
  column, so `│` is three bytes in one.

Every row must take the same columns, or the assembly fails. The pages align
the values with `.columns` directly; no width is written by hand. An index
scaled by 1, 2, 4 or 8 bytes fits an addressing mode
(`lea esi,[.table + r10*.bytes]`); other lengths use `imul`/`add`. The image
addresses are 32-bit in either case. The message texts are similar: each has
`name.bytes` beside it.

The alternate screen is removed on exit, so `vt_summary` writes one persistent
line to the restored main screen describing bytes written and any pending bytes
discarded by Ctrl+Break or console close.

## Character mapping

Startup captures the console output code page before switching output transport
to UTF-8. `init_codepages` prepends that page when it is an SBCS, then appends
the favourites in `HEXED_CODEPAGES`, omitting unavailable, multibyte, and
duplicate entries.

`GetCPInfoExW` validates each candidate. `MultiByteToWideChar` with
`MB_USEGLYPHCHARS` builds the complete 256-entry Unicode map; there is no
embedded CP437 table. Rejected mappings and Unicode C0/C1 controls render as
attribute-marked dots. Valid characters are encoded as UTF-8 for the terminal.

## Geometry and console lifetime

The layout is 76 columns and sixteen bytes per row. Width is taken while the
program runs and restored on exit; height has a four-line minimum and no fixed
maximum.

The modern path is XTWINOPS:

```text
CSI 8 ; rows ; cols t
```

`SetConsoleWindowInfo` and `SetConsoleScreenBufferSize` remain as the legacy
fallback. Under ConPTY they affect the pseudoconsole buffer, not the terminal's
own window. `GetConsoleWindow` does not resize it either: it identifies a hidden
`PseudoConsoleWindow`.

That stand-in is owned by the terminal's real window, though
(`CASCADIA_HOSTING_WINDOW_CLASS`), so `GetAncestor(…, GA_ROOTOWNER)` reaches the
window to place; under conhost the console window is its own root.
`place_window` uses it to centre a console that this process owns
(`GetConsoleProcessList` = 1) on the mouse pointer, within that monitor's work
area. This is the one user32 dependency.

The move runs at startup, before the width is taken. Both hosts apply a resize
asynchronously and finish it from the position they held when it began, so a
`SetWindowPos` made between the request and its completion succeeds and is
then undone. That was measured: the call returned TRUE, and the window stayed
at the system's cascade position. Both hosts keep the top-left corner when
the width changes. So the window is centred at the width it is about to have,
its current pixel width scaled from the captured columns to `LAYOUT_COLS`. The
result lands within about 10 pixels of the pointer under both hosts.

If a host declines the requested width, it is asked only once to avoid an event
loop in which the host and application repeatedly reassert different sizes. A
wider window is used from the left; a narrower one produces the size warning.

The arena grows with `viewrows` and is carved into output, `view`, and `orig`
regions. It never shrinks, avoiding allocation churn during resize. On
allocation failure, the view is shortened to the capacity already available.

Opening and closing either panel also changes `viewrows`. It uses the same
`relayout` path as a window resize, including the save/reload/reapply path for
pending changes, so four panel rows never cover bytes that the editor still
considers visible and editable.

Nothing is painted until the first `WINDOW_BUFFER_SIZE_EVENT` after alternate
screen activation. Startup and subsequent resize therefore share the same
geometry, load, and repaint path. The event's buffer size is only a fallback;
`read_window` prefers `srWindow` and retains its top-row origin for cursor
placement.

## PE and NEWCOFF policy

### Low fixed-base PE header

`program CONSOLE,mainCRTStartup` and `response` in `hexed.asm` write:

```text
/NODEFAULTLIB
/BASE:0x10000
/DYNAMICBASE:NO
/SUBSYSTEM:CONSOLE,10.0
/ENTRY:mainCRTStartup
/DEBUG:FULL
/INCREMENTAL:NO
hexed.obj
kernel32.lib  user32.lib  view.obj  paint.obj  data_forms.obj
/RELEASE
/VERSION:<time-based>
```

The image loads at `10000h` with relocations stripped, so every image address
is a 32-bit value and can be an immediate or a displacement on its own
(`mov esi,label`, `[table + rax*8]`). It keeps `NX_COMPAT`. It has no
`DYNAMIC_BASE`: that is the memory model.

Subsystem 10.0 normal launch requires a valid Load Configuration Directory.
Without it, Windows rejects the image with `0xC000007B` before reaching the
entry point. `program` emits `_load_config_used`: the 148-byte legacy prefix
through `GuardFlags`, unused pointers null, and
`IMAGE_GUARD_SECURITY_COOKIE_UNUSED`. The linker publishes it as data-directory
entry 10.

`/DEBUG:FULL` and `/INCREMENTAL:NO` come from `NEWCOFF.DEBUG`: `program`
writes them whenever it is set and nonzero. The objects' CodeView records
(`.debug$S`) reach the PDB only through `/DEBUG`; without it the linker drops
them. Unwind data (`.pdata`, `.xdata`) is part of the image either way.
`/DEBUG` alone would also link incrementally.

### Uninitialized NEWCOFF data

`anchor.inc` declares BSS this way, and nothing else here declares a section.
The intended BSS declaration is:

```asm
section '.bss' readable writeable align 64
```

Do not add the `data` attribute. With only uninitialized declarations and no
emitted bytes, NEWCOFF derives `IMAGE_SCN_CNT_UNINITIALIZED_DATA` and sets
`PointerToRawData` to zero.

BSS must remain separate from initialized data. COFF object-section
`VirtualSize` is reserved and must be zero; unlike a PE image, an object section
cannot describe a logical tail larger than its raw initialized prefix.

Adding `data` marks the section `IMAGE_SCN_CNT_INITIALIZED_DATA`. Combining that
with NEWCOFF's derived uninitialized flag and zero raw pointer makes the linker
interpret bytes at file offset zero as initial state. The result can load
without fault while global state contains object-header bytes instead of zeros.

### CALM interceptor ordering

[`vt.inc`](vt.inc) installs a `calminstruction ?` catch-all for output
fragment notation. It must be included after local `struct` declarations, so
each module includes `namespace.inc`, then its SDK headers, then `hexed.h`, then
`vt.inc`.

`struct` and `ends` move the `?` handler chain with `mvmacro` and `mvstruc`.
Installing a catch-all across that shuffle can route field declarations through
the wrong handler and define fields twice. The SDK's records
are unaffected because each module's headers declare them before the catch-all
exists.

## Verification record

The port was run against the original build with the same harness: the same
file, then first paint, hex entry, F4 data forms, Tab and character entry, F2
write, PgDn, and Esc Esc. All seven screens matched character for character,
the written files matched byte for byte, and both exited. The record below is
the original's.

The editor has been exercised in a live console by attaching a harness, feeding
`INPUT_RECORD`s with `WriteConsoleInput`, and reading the result with
`ReadConsoleOutputCharacter` and console-attribute APIs.

Verified behavior includes:

- initial `WINDOW_BUFFER_SIZE_EVENT` and first paint
- all keyboard navigation, wheel scrolling, and click placement
- hexadecimal and character entry
- pending-change gating when page, goto, exit, or resize would evict changes
- write, restore, and prompt cancellation paths
- width acquisition and exact width/height restoration on exit
- dynamic heights through 64 lines
- recovery from a window below 76 by four
- partial final rows and cursor clamping on a five-byte file
- read-only opening and edit refusal
- only the intended file values differ after a write
- console modes, code page, and terminal state restored on exit
- no stale cursor highlight after scrolling in either direction
- startup SBCS capture and `F3` filtering/cycling
- complete 76-column footer and distinct prompt attributes
- persistent `written` and `unchanged` exit summaries
- PE subsystem 10.0 normal launch with the load-config directory present

Since the port, the same harness has verified the following.
- **`F6` decimal offsets:** the ruler label and right-aligned addresses.
- **Ten-digit offsets:** on a 1,000,000,016-byte file, the address column
  shows the low nine digits and the footer field shows `999999568`.
- **The footer field** follows the cursor in both modes.
- **Ctrl+G accepts** `0x1F0`, `$22F` (past the end, so the last byte) and
  `3Ah`.
- **Ctrl+G editing:**
  - the hex-mode prefill `0x`, removed with Backspace before `16` is typed;
  - a lone `x` keeps the line open;
  - `Esc` closes it without arming `Esc Esc`.
- **Window placement** under both conhost and Windows Terminal.

The default screens, written files and every data-forms page still match the
original build. With the tables laid out by `label_rows`, and linked with
`/DEBUG`, the data-forms pages are still identical, `n/a` included.
`hexed.pdb` holds 1,222 line entries for `hexed.asm` and the 41 procs.

The data-form renderer also has focused output-vector coverage for binary32
pi, signed 8-/32-/64-bit minima, unsigned 64-bit maximum, and incomplete input.
Float, signed, and unsigned rows were checked for their exact right-edge
positions, including the shorter `u8`/`s8` label fields and signed `-1`.

Not exercised:

- files at the 4 GiB boundary
- console hosts other than Windows Terminal on Windows 11
- the live `DISCARDED` summary path

The discard count follows the same exit path, but reliably driving Ctrl+Break or
console close from the harness also tears down the console that must be inspected.
