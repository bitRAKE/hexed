# hexed roadmap

Features that need more thought before they are built. Each one has to fit
the editor's rules: the view is the editable surface, every navigation goes
through `nav_request`, and every event is one frame and one write.

## Files of 4 GiB and over

Today they are refused because the address column is eight hex digits. The
column can truncate instead, as decimal offsets already do. The footer's
offset field then carries the whole offset.

Already 64-bit: `file_size`, `view_off`, `goto_target`, the view arithmetic in
`hexed.asm` and `view.asm`, `SetFilePointerEx`, and `parse_goto`.

Still 32-bit, all in `paint.asm`:
- the address column (`render_row` adds a dword of `view_off`);
- the footer's byte count (`emit_dec` of a dword);
- the offset field (`render_field`);
- `emit_u32` itself.

Decisions:
- How the field shows a hex offset over eight digits. It has ten columns:
  `0x` and eight digits, then either sixteen digits without `0x`, or the low
  ten digits.
- Whether the address column marks a truncated offset, e.g. a dim leading `…`.
- The Ctrl+G entry line's ten characters, which a sixteen-digit hex offset
  outgrows.

## Search

Find the next or previous occurrence, starting at the cursor.

Decisions:
- **What to search for:**
  - hex bytes (`4D 5A`), with or without wildcards (`4D ?? 90`);
  - text in the active code page or in UTF-16;
  - a number in one of the data forms (u32 LE, f32, ...) using the F4 panel's
    vocabulary;
  - which of these share one entry line, and how it says which it is reading.
- **Where it is typed:** the footer's field is ten characters, enough for
  Ctrl+G but not for a pattern. Options are the prompt line or a panel like F1
  and F4.
- **Finding a match outside the view** is a navigation, and so meets the
  pending-changes prompt. A match must not be lost to that prompt's cancel.
- **Reading the file:** a search reads well past the view, so it needs its
  own buffer and must not disturb `view`/`orig`.
- **Large files:** progress and cancellation, since the event loop is the
  only thread.

## Copy

Put bytes on the clipboard.

Decisions:
- **What is selected.** There is no selection today, only the cursor.
  Shift+arrows extending from the cursor is the usual model, but a selection
  that leaves the view meets the same containment question as an edit.
- **Which forms:**
  - hex text (`4D 5A 90`);
  - a C or assembler array (`db 4Dh,5Ah`);
  - base64;
  - the text the character pane shows;
  - raw bytes;
  - the F4 panel's current value.
- **The clipboard API is user32**, which hexed now links only for window
  placement. The copy forms decide whether it also needs `CF_UNICODETEXT`
  conversion.

## Status messages

`HexState.msg` is still set ("written", "read-only", "out of memory: view
shortened"), but the compact footer no longer shows it. The offset field
could show a message briefly, replacing the offset until the next event.
That needs a rule for which wins when both have something to say.

## Debug level and build time

`policy.inc` sets `NEWCOFF.DEBUG := 6`. That installs the line tracker, a
`macro ?` that sees every assembled line, header lines included.

| Module | Level 6 | Level 1 |
|---|---|---|
| `hexed.asm` | 5.9 s | 0.69 s |
| `view.asm` | 1.2 s | 0.25 s |
| `paint.asm` | 2.7 s | 0.26 s |
| `data_forms.asm` | 1.7 s | 0.08 s |

Level 1 still emits `.pdata`, `.xdata` and `.debug$S`: unwind data and
CodeView procedures, without per-line records.

Either level links with `/DEBUG:FULL`, which `program` writes whenever
`NEWCOFF.DEBUG` is set, so the PDB has the procedures at level 1 and the
lines too at level 6.

Option: level 1 by default, and level 6 only when stepping by source line in
a debugger, for example chosen from the build command.
