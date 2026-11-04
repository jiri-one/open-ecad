// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:ecad_core/ecad_core.dart';

const syntheticPdfPng =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGO4o6HxHwAFPAIsDsQvxQAAAABJRU5ErkJggg==';

DrawingElement syntheticPdfBorder(String id) => DrawingElement(
  id: id,
  kind: DrawingKind.path,
  position: const Vec2(10, 10),
  width: 400,
  height: 277,
  stroke: '#112233',
  strokeWidth: .4,
  path: [
    PathSegment(verb: PathVerb.moveTo, points: [const Vec2(0, 0)]),
    PathSegment(verb: PathVerb.lineTo, points: [const Vec2(400, 0)]),
    PathSegment(verb: PathVerb.lineTo, points: [const Vec2(400, 277)]),
    PathSegment(verb: PathVerb.lineTo, points: [const Vec2(0, 277)]),
    PathSegment(verb: PathVerb.close),
    PathSegment(verb: PathVerb.moveTo, points: [const Vec2(280, 255)]),
    PathSegment(verb: PathVerb.lineTo, points: [const Vec2(400, 255)]),
  ],
);

EcadProject syntheticPdfProject({int pages = 1, bool border = true}) =>
    EcadProject(
      id: 'pdf-import-test',
      name: 'Syntetické PDF',
      documentFields: {'company': 'Importované údaje'},
      pages: [
        for (var i = 1; i <= pages; i++)
          Sheet(
            id: 'page$i',
            name: 'Strana $i',
            number: '$i',
            sourcePage: i,
            frame: const FrameChoice.none(),
            width: 420,
            height: 297,
            graphics: [
              if (border) syntheticPdfBorder('border$i'),
              DrawingElement(
                id: 'text$i',
                kind: DrawingKind.text,
                position: const Vec2(70, 90),
                width: 80,
                height: 12,
                fontSize: 12,
                text: 'Zkouška $i',
                fill: '#334455',
                bold: true,
              ),
              DrawingElement(
                id: 'image$i',
                kind: DrawingKind.image,
                position: const Vec2(200, 100),
                width: 25,
                height: 20,
                imageData: syntheticPdfPng,
                opacity: .8,
              ),
            ],
          ),
      ],
    );
