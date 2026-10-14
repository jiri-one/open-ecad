# Third-party notices

Original Open ECAD code, original electrical symbols and the application mark
are licensed under **GPL-3.0-or-later**; see [LICENSE](LICENSE). The project is
not affiliated with EPLAN, Autodesk or QElectroTech. No QElectroTech source code
or symbol collection is included in this prototype.

Third-party software retains its own license. Exact resolved package versions
are recorded in `pubspec.lock` and `packages/ecad_core/pubspec.lock`.

| Component | License / attribution |
| --- | --- |
| Flutter, Dart and Flutter-generated platform scaffold | BSD-style licenses, The Flutter Authors / Dart project authors |
| Material icon font bundled by Flutter | Apache-2.0, Google / Material Design authors |
| `cupertino_icons` | MIT, Vladimir Kharlampidi; platform-adaptive controls |
| `file_selector`, `shared_preferences` and platform implementations | BSD-3-Clause, The Flutter Authors |
| `http`, `web` and Dart package dependencies | Their package licenses, included in Flutter license assets |
| `pdf` | Apache-2.0, David PHAM-VAN and contributors |
| `image` | MIT, Brendan Duncan and contributors; PNG normalization for PDF export |
| Noto Sans Regular and SemiBold | SIL Open Font License 1.1, The Noto Project Authors; complete notice in [assets/fonts/LICENSE.txt](assets/fonts/LICENSE.txt) |
| Optional standalone PDF converter: PyMuPDF / MuPDF | GNU AGPL-3.0 or a commercial license from Artifex; pinned separately in `scripts/import_pdf_requirements.txt`. Not linked into the Flutter app. See [PyMuPDF licensing](https://pymupdf.readthedocs.io/en/latest/about.html#license-and-copyright). |

The two Noto font files are bundled locally for UI and PDF text; no remote font
service is required. They are unmodified copies from the installed Noto Sans
distribution. The original Open ECAD SVG is in `assets/brand/open-ecad.svg`;
`scripts/generate_icons.sh` produces the platform icons from that vector source.

The optional PDF helper runs as a local Python process and has its own dependency
installation. Keep PyMuPDF/MuPDF's notices and comply with their license when
redistributing that runtime. Imported document fonts are not bundled or copied
into project files; imported text uses the existing Noto Sans fonts.

Flutter builds collect package license texts in the generated `NOTICES` or
`NOTICES.Z` asset. Keep those files, the complete application bundle, this notice
and LICENSE when packaging the app. Sources and changes must be provided in
accordance with the applicable licenses when distributing the GPL application.

The project's GPL version is 3 or later, including compatibility with its
Apache-2.0 PDF dependency; see the [Apache Software Foundation's compatibility
statement](https://apache.org/licenses/GPL-compatibility.html).
