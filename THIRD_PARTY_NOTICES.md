# Third-party notices

## Runtime exercise demonstrations

Selected exercise animations are requested at runtime from the official free
[ExerciseDB V1 API/CDN](https://docs.ascendapi.com/products/edb-v1/overview) by
AscendAPI. The app uses explicit ExerciseDB media IDs and displays the provider and
copyright attribution next to every animation.

The exercise media is not part of openGym's AGPL license. The dataset used by
openGym identifies the underlying media as `© Gym visual — https://gymvisual.com/`
and states that cloning its repository does not transfer a media license. For that
reason MorningCoach does not copy those GIFs from openGym or the dataset, and no raw
exercise media is committed to this repository or bundled into the APK. The app
requests the official hosted URLs only for the specifically mapped movement demos.

## MuscleMap anatomical path geometry

The front/back anatomical SVG path geometry in
`lib/ui/widgets/muscle_map_paths.dart` is derived directly from
[`melihcolpan/MuscleMap`](https://github.com/melihcolpan/MuscleMap), commit
`7dc03071e03052e8bd4f6351e9176994cd28aa7d`, specifically
`MaleFrontPaths.swift`, `MaleBackPaths.swift`, and the view boxes in
`BodyPathData.swift`. The source path strings were mechanically transcribed to
Dart and are used under the MIT License below. No openGym program source or
exercise media is included.

MIT License

Copyright (c) 2026 Melih Colpan

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
