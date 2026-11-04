# LAB Cycles helper protocol 1

The private `lab-cycles-render` process has two commands: `--capabilities` writes
one JSON object; `--render /absolute/job/manifest.json` emits newline-delimited JSON
events. Diagnostic output goes to stderr. SIGTERM cancels an active session.
It has no network or Blender dependency.

Manifest: `version`, `jobID`, `sourceRevision`, `width`, `height`, `samples`,
`adaptiveThreshold`, `denoise`, `device` (`auto`, `cpu`, `metal`), `seed`,
`transparent`, `exposureEV`, `maxBounces`, `outputDirectory`, `meshes`, `curves`, `materials`, `camera`,
`lights`, `background`. All input resources and output files are inside the job
directory. Arrays referenced by `{path,count}` use little endian binary data;
counts mean elements, not bytes or vector components.

Meshes contain `id`, FLOAT64 xyz `positions`, optional FLOAT32 xyz `normals`,
optional FLOAT32 xy `uvs`, UINT32 `triangles` (index count divisible by 3), optional
UINT32 `materialIndices` (one global material index per triangle), and `transform`.
Optional `uvs1` is a second FLOAT32 xy UV set; `colors` is FLOAT32 linear RGBA per
vertex, multiplied into materials whose `useVertexColor` is true. UV origin is
top-left; the helper converts it after each texture's affine mapping.
Curves contain FLOAT64 xyz `points`, FLOAT32 `radii`, UINT32 `firstKey` (start of
each curve; last ends at points.count), global `materialIndex`, and `transform`.
Their optional FLOAT32 xy `uvs`/`uvs1` contain one physical millimeter coordinate
per key. U follows authored strand arc length; V is an authored circumferential
offset. Swift generates UV0 from transformed Catmull-Rom arc length when absent;
legacy helper-only inputs fall back to transformed polyline length. U resets at
each strand. The helper adds the circumferential distance at each shading point
using a parallel-transport frame and interpolated radius. Named per-key attributes
preserve both UV sets; texture scaleMM becomes inverse millimeters per repeat.
Circumference uses Cycles' equivalent-volume radius scaling for nonuniform object
transforms, not an exact elliptical cross section. Curve normal maps use the
actual curve tangent and geometric normal, including the normalDetail chain.
Their tangent basis follows the selected UV direction, independent texture
rotation/reflection and mirrored-repeat orientation. Arc coordinates are
interpolated between keys, so densely sampled curves provide more uniform
physical repeats through rapidly changing curvature.
True textured displacement is unsupported on curves and rejected explicitly.
Positions, radii and transform translation are millimeters. Matrices are
column-major 4x4. World +Y is up; camera +X right, +Y up, +Z forward.

Materials: linear `baseColor` RGBA, `roughness`, `metallic`, `ior`, `transmission`,
`diffuseTransmission`, `subsurface`, `subsurfaceRadiusMM`, `sheen`,
`sheenRoughness`, linear `sheenTint`, `anisotropy`, `anisotropyRotation`, `coat`,
`coatRoughness`, linear `emissionColor`, `emissionStrength`, `normalScale`,
`normalStrength` (0–10, default 1), `bumpStrength`, `displacementScaleMM`, `displacementMidlevel`, `alphaMode`,
`alphaCutoff`, `unlit`, `useVertexColor`. `textures` maps channel names to objects containing
`path`, `colorSpace` (`srgb`, `linear` or `data`), `uvIndex`, `wrapS`, `wrapT`, `scale`,
`offset`, `rotationDegrees`, `channel` (rgba/red/green/blue/alpha). Both UV0 and UV1
are supported, as are independent repeat/clamp/mirror modes. Floating point
textures use `format:rgba32f`, `width`, `height` and little-endian straight RGBA
samples; a temporary float EXR preserves their numeric values without clamping,
and the texture node explicitly declares their straight alpha. The node applies
the requested encoding through Cycles' built-ins (`__builtin_srgb`,
`scene_linear`, `data`), without an external OCIO configuration. Both texture and
environment nodes use these identities. Supported channels are baseColor, roughness,
metallic, normal, emission, alpha, bump, displacement, anisotropy, sheen, coat,
transmission, diffuseTransmission, subsurface and sheenTint.
`artwork` is a separate alpha-over color layer, preserving substrate shading;
`normalDetail` combines a second tangent normal with the original normal before
the bump node. `normalStrength` controls that detail map when present; otherwise
it multiplies `normalScale` for the ordinary normal map. Mesh and curve tangent
normal directions follow the selected UV set, rotation, signed scale and mirrored
repeat parity as well as the transformed sampling coordinates.
Material `physicalLayers` accepts up to sixteen ordered objects
`{mask:<texture descriptor>,appearance?:<material field overrides>,roughness?:0...1,metallic?:0...1}`.
Omitted appearance inherits substrate optics. Explicit roughness/metallic factors
replace inherited channel textures; a map authored in the layer's appearance
instead modulates that factor. Each mask mixes the underlying and overlaid
physical closures exactly once; physical substrate maps exclude baked finishes.
Authored layer normal/bump/displacement replaces substrate microdetail while
retaining the base macro normal map. Explicit layer displacement
uses the same mask. Textured displacement uses world-space millimeter distance.
Only meshes that use nonzero displacement are linearly tessellated before Cycles
evaluates the height field. Shared edge midpoints preserve topology and all vertex
attributes. `displacementDicingRate` defaults to 2 projected pixels;
`displacementMaxSubdivisions` defaults to 10 and `displacementMaxTriangles` to
2,000,000 across displaced meshes. Exceeding either budget fails with an
actionable diagnostic rather than allocating unbounded geometry. Cycles recomputes
displaced normals; the same height is not applied again as automatic bump.

Camera: `type` (`perspective` or `orthographic`), `transform`, `fovRadians`
(vertical angle), `orthoScale` (vertical millimeters), `near`, `far`, optional
`apertureFStop`, `focusDistanceMM`. Lights: `type` (`area`, `point`, `sun`),
`transform` (local -Z direction), `power`, linear `color`, `size` [width,height]
millimeters. Area and point power is watts; sun strength is irradiance.
Area lights accept `shape` rectangle (default) or disk.
Background: linear `color`, `strength`, optional `texture`, `rotationDegrees`.

Events carry `type`, `jobID`, `sourceRevision`, `device`, `engineVersion`.
`progress` adds `sample`, `totalSamples`, `progress`, `status`. Explicit `phase`
values include `preparing` for displacement tessellation and `denoising` at
the pinned engine's actual OIDN work entry, observed through its public log
callback. Rendering uses offscreen DisplayDriver scheduling with at most 32
samples per work batch; no application window or OpenGL context is created.
`frame` adds `framePath` (PNG, top-down sRGB), actual completed sample count and dimensions; optional
`linearFramePath` is top-down FLOAT32 RGBA scene-linear data.
`completed` adds `finalPNG`, `finalEXR`, dimensions, actual `samplesCompleted`,
`samplesRequested`, `denoiser`, `preparationSeconds`, `renderSeconds`, optional
`denoiseSeconds`, and `engineReportPath`. Stage times come from the pinned
engine's measured report (six decimal seconds); preparation includes manifest,
geometry, texture and device setup. `seconds` covers the session wall clock.
`error` adds `message`. Frame files are replaced atomically; a published event
always refers to complete data. PNG uses standard sRGB encoding; EXR retains
scene-linear values. The same encoding is used for progressive and final PNGs.
`displayTransform:LAB-sRGB-v1` is pinned in the engine lock: unpremultiply,
multiply by 2^exposureEV, apply the standard sRGB transfer curve, and clamp only
the eight-bit display output. There is no additional photographic tone mapping;
EXR remains premultiplied scene-linear with HDR values retained.
The PNG writer is explicitly told its encoded RGBA is already straight, avoiding
an additional unpremultiply inside OpenImageIO.
Events include `fallbackReason` when automatic device selection uses CPU because
Metal is unavailable. An explicitly requested unavailable Metal device fails.
Only pinned upstream Metal library compilation or pipeline activation failures
before the first sample emit `error.category:metalInitialization`. The client may
retry an Auto job once on CPU, reporting the failure reason; explicit Metal and
ordinary scene/resource/memory errors are never retried.
`LAB_CYCLES_CACHE_DIR` overrides the normal user cache directory for isolated tests.
