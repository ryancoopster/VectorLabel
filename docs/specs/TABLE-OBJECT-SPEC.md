# Table object — spec (draft; integration points filled from code maps)

A new designer object type: a **table** whose cells are text objects. Renders in all
three paths (Designer canvas, Print HTML preview, Swift print rasterizer).

## Schema (template JSON, inches like all objects)

```js
{
  id: "o12",
  t: "tb",
  x: 0.1, y: 0.1,            // top-left, inches
  w: 1.3, h: 0.8,            // overall size, inches (ALWAYS == sum(cols) / sum(rows))
  cols: [0.5, 0.4, 0.4],     // column widths, inches
  rows: [0.3, 0.25, 0.25],   // row heights, inches
  lockCols: false,           // all columns forced equal (w/cols.length)
  lockRows: false,           // all rows forced equal (h/rows.length)
  lockSize: false,           // overall w/h locked: inner line drags redistribute
  lw: 1,                     // grid/border line width (same units as ln/rc objects)
  cells: [                   // row-major, rows.length × cols.length
    [ {CELL}, {CELL}, {CELL} ],
    ...
  ]
}
```

**CELL** = the exact tx-object text fields (NO x/y/w/h/id — geometry comes from the grid):
`mode ("static"|"field"|"formula"), text, field, f, fs, font, bold, italic, underline,
al, valign, wrapText, tracking, stretch, autoScale`. Defaults identical to a new tx
object. Cells resolve content through the SAME textValue()/txMode() as tx.

Invariants (enforced in sanitize + every mutation):
- `cols.length >= 1`, `rows.length >= 1`, `cells` shape matches rows×cols.
- `w == sum(cols)` and `h == sum(rows)` (renormalize after any edit).
- `lockCols` ⇒ all cols equal; `lockRows` ⇒ all rows equal.
- Min column width / row height: 0.05 in (clamp on drag + numeric entry).

## Designer interactions

**Add**: "Table" button in the Add sidebar → small modal ("Insert table"): Rows [n],
Columns [n] (1–20 each, default 3×3) + Add/Cancel. New table sized to a sensible default
(≈60% of printable area, uniform cells), placed like other new objects.

**Selection model**
- Click table (when not selected): selects the table object → normal move/resize
  grab handles for the WHOLE table (like any object).
- Click a cell while the table is selected (or double-click a cell any time): selects
  that CELL. Selected cell(s) get a highlight outline.
- Shift-click another cell: selects the rectangular RANGE between anchor and clicked.
- Cmd-click: toggles individual cells in/out of the selection.
- Escape: cell selection → table selection → none.
- Cell selection state lives in designer state (e.g. S._tblSel = {objId, anchor:[r,c],
  cells:Set("r,c")}); NOT serialized.

**Properties panel**
- Table selected (no cell): overall Width/Height numeric inputs (respect lockSize
  toggle), Lock table size checkbox, Lock columns (equal) checkbox, Lock rows (equal)
  checkbox — each lock, when enabled, shows a numeric input (column width / row height)
  that sets the uniform size (table w/h updates to match unless lockSize, in which case
  it's clamped/redistributed), grid line width, plus the standard x/y position inputs.
- Cell(s) selected: the FULL text formatting panel (same controls as tx: mode
  static/field/formula incl. formula editor + field picker, font, size, B/I/U,
  align/valign, wrap, tracking, stretch, autoScale), applied to ALL selected cells
  (multi-select shows 'mixed' like existing multi-object formatting). Also: numeric
  "Column width" / "Row height" inputs that apply to the columns/rows covered by the
  selection. Plus buttons: "+ Row above / below", "+ Column left / right", "Delete
  row(s)", "Delete column(s)" (operate on selection; deleting the last row/col is
  prevented).

**Right-click (context menu) on a cell**
- Add row above / Add row below / Add column left / Add column right
- Delete row / Delete column
- "Set row height…" → dialog with numeric inches input, applies to that cell's ROW only
- "Set column width…" → dialog, applies to that cell's COLUMN only
- Copy cells / Paste cells (enabled when applicable)

**Resizing**
- Whole table: standard object grab handles + panel W/H. When `lockSize` is ON the
  handles are hidden/disabled and W/H inputs read-only.
- Column/row lines: hovering within ±3px of an inner grid line shows col-resize /
  row-resize cursor; dragging moves that boundary:
  - lockSize OFF: the line's leading col/row resizes; the table w/h grows/shrinks
    (trailing cols/rows keep their sizes).
  - lockSize ON: the boundary moves WITHIN the table — leading col/row grows while the
    trailing neighbor shrinks (sum preserved), clamped at min size.
  - lockCols/lockRows ON: dragging a col/row line resizes ALL cols/rows together
    (uniform maintained); with lockSize also ON the drag is a no-op (toast explains).
- Dragging the OUTER edges = whole-table resize (existing handles); distributes the
  delta proportionally across cols/rows (or equally when locked-uniform).

**Cell text entry**: double-click a selected cell opens the same editing path a tx
object uses (properties panel focus; if tx supports inline editing, mirror it).

**Copy/paste cells**
- Cmd-C with cells selected: copies the selection's rectangular bounding block (cell
  content objects + relative geometry) to an in-page clipboard (window._vlCellClip),
  as well as TSV text to the system clipboard for pasting into spreadsheets.
- Cmd-V with a cell selected: pastes the block anchored at the selected cell (into the
  same or ANOTHER table object); grows rows/cols? NO — clips to the target table's
  bounds (simplest predictable rule).
- Cmd-C/V with the TABLE (not cells) selected: existing whole-object copy/paste.

**Undo/keyboard**: all mutations go through the existing mutation/undo path (fill in
from map). Delete with cells selected clears cell CONTENT (does not delete the table);
Delete with table selected deletes the object (existing behavior).

## Print render (Print HTML + Swift — must agree)

- Draw grid: outer border + inner lines at cumulative col/row offsets, line width `lw`
  (same stroke treatment as ln/rc objects), black.
- Each cell renders EXACTLY like a tx object whose box is the cell rect inset by a
  1px-equivalent padding: same font sizing, stretch (scaleX), wrap, autoscale
  (shrink-to-fit, never ellipsize — reuse the existing autofit pass), field/formula
  resolution per record, error handling (⚠ like tx on formula error).
- Empty cells render nothing (grid still drawn).
- 90° canvas rotation: tables rotate with the label exactly like other objects (no
  special casing beyond what tx does).

## Swift template coding

- VLTemplate obj decoding must round-trip ALL new fields (cols/rows/locks/cells) for
  both .vltmp and .vlcus. (Integration detail from map: if Codable is strictly typed,
  add the fields/types; cells decode as nested text-ish structs.)
- Swift print rasterizer: add `tb` case — grid stroke + per-cell text via the SAME
  drawText path tx uses (autoscale agreement rule applies).

## Integration points (from code maps — line numbers as of commit a4ac498)

### VectorLabelDesigner.html (5036 lines; inches × SC=185, BLEED_IN=2 offset, zoom = CSS scale wrapper)
- `buildCanvas` per-type if-chain 1164-1259 → add `tb` branch (unknown types return "").
  Reuse the tx recipe (1176-1207): `textValue(cell,rec)`, `fz=Math.max(7,(fs||14)*(sc/100))`,
  `autoFitPx` when `autoScale&&!wrapText`, inner-div style incl. `line-height:1.15`,
  `letter-spacing`, `transform:scaleX(stretch/100)`, `data-autofit="1" data-sx=…`,
  overflow clip (never ellipsis). Draw grid lines as thin divs (`lw` raw px like rc border).
  Per-cell transparent hit divs (mousedown/ctxmenu) rendered only when the table is
  selected; ±3px line-drag strips with col-resize/row-resize cursors.
- `addObj` ~2708-2718 + Add sidebar buttons 1812-1824 (add "Table" button → open insert
  popup first, then create). `objListLabel` 2674-2683 → "Table R×C".
- `buildProps` 1456-1657 (add tb branch: posButtons + lock checkboxes + numeric inputs +
  posSizeBlock) and `buildMultiProps` 1404-1454 (tb-aware or mixed-notice is OK v1).
  When CELLS are selected, buildProps must show the tx-style formatting panel bound to
  the selected cells (sh()/'mixed' pattern), plus row/col size inputs + add/delete
  row/col buttons.
- Cell selection state: `S._tblSel = {id, anchor:[r,c], cells:[["r,c"...]]}` (NOT
  serialized; cleared by normSel when object gone / deselect). Keyboard handler
  (2892-2945): when `S._tblSel` active, Delete clears cell CONTENT, cmd-C/V route to the
  cell clipboard (`window._vlCellClip`), Escape steps cell-sel → table-sel → none
  (existing Escape at 2942 + capture-phase modal Esc at 3877).
- Inline cell editing: mirror startTextEdit/setStaticText contenteditable pattern
  (2514-2520 dblclick detection, S.editingId analog `S._tblEdit={id,r,c}`,
  fitAutoScaleText skips activeElement).
- Mutation contract: `snapshot()` BEFORE each mutation, then edit S.objs immutably
  (uobj), then `R()`. snapshot = undo + markDirty. No redo exists.
- Modals: rows/cols insert popup + "Set row height/column width" → use vlPrompt (4416)
  / symPicker-style imperative overlay (2860). Escape must be self-handled.
- Context menu: copy showCellMenu pattern (4787; item()/sep(), viewport clamp,
  outside-mousedown + Escape dismissal, z-index ≥ 2500). Attach via
  `oncontextmenu="tblCtxMenu(event,'id',r,c)"` on cell hit divs. Escape all interpolated
  values with esc()/escAttr()/jsAttr() (763-765).
- `sanitizeObjs` 3542-3570: whitelist `tb`, coerce numerics (lw, cols[], rows[]),
  validate cells shape (rows×cols), scrub each cell's `font` like top-level, drop
  unknown cell keys. Enforce invariants (w==sum(cols) etc, min 0.05in).
- Column-header drop binding: add the onColTextEnter/onColDropToText-style attrs
  (1192/1247) to cell hit divs → sets that CELL's {mode:'field',field} (stopPropagation
  so canvas drop doesn't fire).
- Existing object copy/paste (_objClipboard, paste regenerates only top-level id) —
  cells have NO ids so tables copy/paste as whole objects for free.
- posSizeBlock W/H inputs: for tb, route through a resize fn that rescales cols/rows
  proportionally (or equally when lockCols/lockRows); disable when lockSize.

### VectorLabelPrint.html (2991 lines)
- `renderLabel` 320-375: add `tb` branch before the `return ""` at 372. sc=SC*scale
  (SC=185 @272); fs*(sc/100); lw raw px (rc convention). Reuse tx recipe 330-351 per
  cell incl. data-autofit/data-sx and {v,e} error ⚠ handling. Must work at all three
  scales (1 / 0.55 / 0.25).
- `sanitizeObjs` 2791-2799: recurse into tb cells — scrub cell.font ([A-Za-z0-9 -]);
  no src in cells.
- textValue 233 / txMode 232 / autoFitPx 278 / fitAutoScaleText 295 all reused as-is.

### Swift (Core)
- TemplateStore.swift `TemplateObject` (7-60): add OPTIONAL fields —
  `cols: [Double]?`, `rows: [Double]?`, `lockCols: Bool?`, `lockRows: Bool?`,
  `lockSize: Bool?`, `cells: [[TableCell]]?` where `TableCell` is a new small Codable
  struct (all-optional: mode,text,field,f,font,fs,bold,italic,underline,al,valign,
  wrapText,tracking,stretch,autoScale). Non-optional additions would break decoding of
  every existing .vltmp/.vlcus.
- LabelTemplate.swift dispatch switch 193-202: `case "tb": drawTable(...)`. Model
  drawTable on drawText (235-381): same mode inference (238-244), CoreText-only font
  resolution (off-main discipline — NO NSFontManager/AppKit), fontSize
  `max(7, fs*185/100)*dpi/185`, autoScale via CTFramesetter shrink-to-fit (never grows,
  clip never ellipsize), stretch as scaleX text matrix. Grid strokes like
  drawLine/drawRect: lw scaled dpi/185, floor 1px. Geometry inches × dpi (rect(for:)
  221-229, designerDPI=185).
- CustomLabelDocument embeds VLTemplate → .vlcus gets tables for free.
- Add a FoundationTests round-trip test: fully-populated tb TemplateObject encode→decode
  equality (no template coding test exists today).

## Out of scope (v1)

- Merged/spanning cells; per-cell borders/fills; header-row styling; row striping.
- Growing a table on paste overflow (clips instead).
- Cross-window cell paste (in-page clipboard + TSV export only).
