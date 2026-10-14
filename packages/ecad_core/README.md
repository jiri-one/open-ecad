# ecad_core

Pure Dart document model, symbol geometry, validation, atomic commands, undo/redo,
and command-line tools for Open ECAD. No Flutter dependency.

The version 3 `.ecad.json` format contains `format: "open-ecad"`,
`formatVersion: 3`, a project ID, name, description, monotonic revision, and
`pages`. Version 1 documents load transparently with their original 1100 × 780
sheet bounds, a visible frame, and an empty graphics collection; version 1 and 2
sheets get the fallback sheet type. Saving writes version 3, so older readers
report `unsupported_format` instead of misreading the file. Other format
versions are rejected.

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
collection. Graphics remain separate from electrical devices and connections.
Imported drawing paths and text do not establish electrical connectivity.

A sheet `type` is `multiLine`, `singleLine`, `cabinetLayout`, or `form`. Saving
always writes it. A missing field (older files, unclassified PDF pages) takes
the compatibility fallback `multiLine`, which says nothing about the page
content; any other value is rejected. The type names the page and its frame
caption; editing and validation rules are the same for every type.
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

`commands.json` accepts an array or a transaction envelope:

```json
{
  "expectedRevision": 0,
  "label": "Rename the project",
  "commands": [
    {"type": "renameProject", "name": "Extraction cabinet"},
    {"type": "moveDevices", "sheetId": "sheet_power", "positions": {
      "dev_motor": {"x": 420, "y": 550}
    }}
  ]
}
```

The engine rejects stale revisions and commits a whole command batch only after
its final document passes structural validation. Undo and redo also increment
the revision; a previously prepared proposal becomes stale even after undo.
Supported types: `addDevice`, `moveDevices`, `updateDevice`, `deleteDevices`,
`addWire`, `deleteWire`, `addSheet`, `renameSheet`, `setSheetType`,
`renameProject`, `addGraphics`, `updateGraphic`, `updateGraphics`,
`moveGraphics`, `deleteGraphics`.
Deleting devices removes their attached wires in the same transaction.
`moveDevices` and `updateDevice` also adjust the manual waypoints next to a
moved or rotated terminal, in the same revision. Other bends are kept when
possible. Unsafe bends are dropped, falling back to an automatic route if needed
to avoid a connected symbol or reach a terminal from the correct side.
`setSheetType` accepts `sheetId` and `sheetType`, for example
`{"type": "setSheetType", "sheetId": "sheet_power", "sheetType": "singleLine"}`.

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
Drawing, device, wire, sheet, and project IDs share one unique namespace.
Directly constructed Dart objects receive the same structural checks as decoded
drawing data, and drawing diagnostics identify their `graphicId` and `sheetId`.

Format limits support large drawing sets: 1024 sheets, 500,000 drawing elements,
10,000 segments per path, and 4,000,000 total path segments. Each text element is
limited to 65,536 characters. PNGs are limited to 16 MiB each and approximately
64 MiB total decoded payload, dimensions at most 16,384 pixels per side, and
64 million pixels per image. Core validation checks base64, the PNG signature,
and IHDR bounds; renderers decode pixels and report corrupt image contents.
CLI input and output are limited to 128 MiB and saved as compact JSON. Existing
device/wire limits remain 20,000 devices, 40,000 wires, and 256 wire waypoints.
Graphic validation is cached on immutable elements so edits avoid rescanning
unchanged path geometry or repeatedly decoding unchanged image payloads.

Warnings include duplicate designations, duplicate connections, and unused
terminals. Warnings allow documents in progress and intentional drawing
boundaries. Validation is not electrical simulation, engineering certification,
or a check of protection sizing or standards compliance.

The two-page demo is explicitly illustrative: a single-line three-phase feeder
(sheet type `singleLine`) and a separate 24 V control example. Cross-sheet component associations,
conductor counts, interlocks, and complete protection design are not modeled.
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
