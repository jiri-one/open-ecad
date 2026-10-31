# ecad_core

Pure Dart document model, symbol geometry, validation, atomic commands, undo/redo,
and command-line tools for Open ECAD. No Flutter dependency.

The version 5 `.oecad` / `.ecad.json` format contains `format: "open-ecad"`,
`formatVersion: 5`, a project ID, name, description, monotonic revision, and
`pages`. The reader accepts versions 4 and 5; saving writes version 5. Older
formats are rejected without automatic migration. The PDF converter emits
version 4 graphics, which the editor can open and save as version 5.

Articles describe products; components represent physical pieces or material;
devices are electrical occurrences bound to component functions and terminals.
Repeated occurrences and mounting views do not increase the physical quantity
in the BOM. Structure uses function (`=`), location (`+`) and product (`-`)
aspects. Continuation links join markers by identity across sheets. Circular
terminal symbols expose one electrical node through one to four connection
points. Mounting layouts use millimetres, shared placements and explicit scales;
BOM report sheets derive their rows from the current project.

During early development the format may change without backward compatibility.

Symbol positions are centers; rotations are degrees clockwise in the screen
coordinate system. Wires reference device IDs and named ports rather than
coordinates, so wires follow moved or rotated symbols. `WireRouter` computes the
orthogonal path that the editor and exports share: it leaves and enters
terminals along their outward axis and avoids the two connected symbols, with
best-effort routing when those symbols overlap. Other devices are not obstacles.
Routing is designed for the editor's 90-degree turns; other rotation angles
in external documents use best-effort geometry.
Each sheet also has
`width`, `height`, `showFrame`, an optional 1-based `sourcePage`, and a `graphics`
collection. `sourcePage` is the page number in the original document, so it may
exceed the sheet count; it is limited to 1,000,000.
Graphics remain separate from electrical devices and connections.
Imported drawing paths and text do not establish electrical connectivity.

A sheet `type` is `multiLine`, `singleLine`, `cabinetLayout`, `form`, or
`billOfMaterials`. Saving always writes it. Unclassified PDF pages use
`multiLine`, which says nothing about their electrical content. Unknown types
are rejected. Electrical sheets support symbols and wires; cabinet layouts
display shared physical placements, and BOM sheets display derived reports.
`SheetTemplates.blankForm()` returns an original blank table of ordinary
graphics with generic captions only.

## Native drawing elements

`DrawingElement` stores editable paths, text, or embedded images. Its `position`
is the local top-left origin; `width` and `height` are the local bounds. Clockwise
`rotation` is around that origin. Path segments use `M` (one point), `L` (one
point), `C` (three points), and `Z` (no points). Coordinates are local to the
element, and path bounds may have zero width or height for straight lines.
Text and image bounds must have positive dimensions. A path starts with `M`.

```json
{
  "id": "drawing_line",
  "kind": "path",
  "position": {"x": 20, "y": 30},
  "width": 100,
  "height": 0,
  "stroke": "#000000",
  "path": [
    {"verb": "M", "points": [{"x": 0, "y": 0}]},
    {"verb": "L", "points": [{"x": 100, "y": 0}]}
  ]
}
```

Optional styles include nullable `stroke` and `fill` in `#RRGGBB` form,
`strokeWidth` (default 1), `opacity` (default 1), `dash` (default empty),
`lineCap` (0 butt, 1 round, 2 square), `lineJoin` (0 miter, 1 round, 2 bevel),
and `evenOdd` (default false). Text uses `text`, `fontSize` (default 12), and
`bold` (default false); renderers fit it within the declared local bounds.
Image `imageData` is raw base64 PNG. External URLs and file references are not
supported. Default drawing fields are omitted when serialized to keep large
documents compact. Drawing models own immutable copies of their collections.

## Commands

From this directory:

```sh
dart pub get
dart run bin/open_ecad.dart sample example.ecad.json
dart run bin/open_ecad.dart validate example.ecad.json --json
dart run bin/open_ecad.dart apply example.ecad.json commands.json updated.ecad.json
dart test
dart analyze
```

From a package depending on `ecad_core`, use `dart run ecad_core:open_ecad`.
One input may be `-` for stdin; output defaults to stdout. Named output files
are saved through a sibling temporary file and renamed after a successful edit.
When the output is a symbolic link, its final target is replaced in the target's
directory and the link is kept. A link without an existing target file is
rejected. Plain-text messages show control characters from project data as
escapes such as `\x1b`; JSON output escapes DEL and C1 controls as well.

`commands.json` accepts an array or a transaction envelope:

```json
{
  "expectedRevision": 0,
  "label": "Rename the project",
  "commands": [
    {"type": "renameProject", "name": "Extraction cabinet"},
    {"type": "moveDevices", "sheetId": "sheet_control", "positions": {
      "dev_coil": {"x": 420, "y": 550}
    }}
  ]
}
```

The engine rejects stale revisions and commits a whole command batch only after
its final document passes structural validation. Undo and redo also increment
the revision; a previously prepared proposal becomes stale even after undo.
Common command types include `addArticle`, `updateArticle`, `deleteArticle`,
`addComponent`, `updateComponent`, `deleteComponent`, `addDevice`, `moveDevices`, `updateDevice`, `updateDevices`,
`deleteDevices`, `addWire`, `deleteWire`, `addSheet`, `renameSheet`,
`setSheetType`, `renameProject`, `addGraphics`, `updateGraphic`,
`updateGraphics`, `moveGraphics`, `deleteGraphics`, plus commands for terminal
strips, continuation links/markers, wire corners, mounting layouts and structure.
The full JSON command contract is defined by `EcadCommand.fromJson` in
`lib/src/commands.dart`.
Commands apply in order, each seeing the result of the previous ones. A batch
copies each sheet collection it edits once and validates the result once, so
many small commands cost about as much as one bulk command.
`updateDevices` accepts `sheetId` and a nonempty `devices` array of complete
replacements with distinct existing IDs, such as a rotated selection.
Deleting devices removes their attached wires in the same transaction.
`moveDevices`, `updateDevice` and `updateDevices` also adjust the manual
waypoints next to a moved or rotated terminal, in the same revision. Devices
changed by one command move together, so a wire between two of them is adjusted
once. Other bends are kept when possible. Unsafe bends are dropped, falling back
to an automatic route if needed to avoid a connected symbol or reach a terminal
from the correct side.
`setSheetType` accepts `sheetId` and `sheetType`, for example
`{"type": "setSheetType", "sheetId": "sheet_control", "sheetType": "singleLine"}`.

`addGraphics` accepts `sheetId` and a nonempty `graphics` array;
`updateGraphic` accepts `sheetId` and a complete replacement `graphic` with an
existing ID. `updateGraphics` accepts a nonempty `graphics` array of replacements
with distinct existing IDs and preserves their original drawing order; one
bulk command can update more than 1000 elements. `moveGraphics` uses the same ID-to-position map as `moveDevices`;
`deleteGraphics` accepts a nonempty array of distinct `ids`. Graphic commands
can be mixed with device/wire commands in one atomic revision and undo step.
Duplicating geometry uses `copyWith(id: newId('graphic'), ...)` and `AddGraphics`.

## Integrity boundaries

Decoders reject unknown fields/types/versions, nonfinite coordinates, excessive
text or collections, and invalid command shapes. The engine additionally rejects
duplicate identifiers, missing devices/ports, wires to the same endpoint, invalid
metadata, and out-of-range geometry. Project imports should construct a
`ProjectEngine` after decoding, or explicitly inspect `validateProject` results.
Persistent object IDs share one unique namespace; symbol port IDs are local
to their symbol. Components retain their identity when occurrences change.
Directly constructed Dart objects receive the same structural checks as decoded
drawing data, and drawing diagnostics identify their `graphicId` and `sheetId`.

Format limits support large drawing sets: 1024 sheets, source page numbers up to
1,000,000, 500,000 drawing elements, 10,000 segments per path, and 4,000,000
total path segments. Each text element is limited to 65,536 characters.
PNGs are limited to 16 MiB each and approximately 64 MiB total decoded payload,
dimensions at most 16,384 pixels per side, and
64 million pixels per image. Core validation checks base64, the PNG signature,
and IHDR bounds; renderers decode pixels and report corrupt image contents.
CLI input and output are limited to 128 MiB and saved as compact JSON. Existing
device/wire limits remain 20,000 devices, 40,000 wires, and 256 wire waypoints.
Graphic validation is cached on immutable elements, so unchanged elements are
not checked again. A `copyWith` copy that keeps the same image payload reuses its
PNG check, so moving or restyling an image does not decode it again; the copy's
geometry and style are always checked.

Warnings allow documents in progress and intentional open drawing boundaries.
Reference uniqueness, terminal bindings and missing physical dependencies are
validated before committing a transaction. Validation is not electrical simulation, engineering certification,
or a check of protection sizing or standards compliance.

The five-sheet demo is illustrative: a coil, a contact with a reference
occurrence, a mounting view, an article BOM and a component list. All electrical
occurrences represent one physical relay. It includes open connection points
and unspecified material; it is not a complete installation design.
The code and simple symbol definitions are original; no QElectroTech code or
symbol data is imported.

## Reproducible core benchmark

`dart run bin/benchmark.dart --mode jit` measures deterministic 1,000- and
10,000-device projects. Compile the same file with `dart compile exe` and pass
`--mode aot` for a native run. The harness checks fixture integrity and undo
restoration before timing, and emits raw samples, medians, p95, and environment
metadata. Use `--help` for fixture generation and sample-count options.
Benchmark results remain local; the source repository includes the synthetic
fixture generator and benchmark code, without collected data.

SPDX-License-Identifier: GPL-3.0-or-later
