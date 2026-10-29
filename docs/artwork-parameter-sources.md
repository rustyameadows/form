# Parameterized flat sources

A flat source keeps the existing `Artwork`, stable element/path/seam identities,
and saved Recipe controls. Numeric bindings relate those controls to the same
canonical geometry used by Canvas, cutting layouts and assembled surfaces.
There is no second sewing generator or per-model application plugin.

Use `form_create_recipe` with `parts: []` for an independent source that needs
controls but no primitive solid. Add ordinary vector elements through
`form_edit_artwork`, and annotate sewing pieces and seams through its existing
commands. Then install rules through `form_update_object`:

```json
{
  "object_id": "<source object UUID>",
  "artwork_parameter_bindings": [
    {
      "id": "panel-span",
      "elementID": "<existing element UUID>",
      "property": "width",
      "value": "span"
    },
    {
      "id": "cut-allowance",
      "elementID": "<existing sewing element UUID>",
      "property": "seamAllowance",
      "value": "allowance"
    }
  ]
}
```

The expressions use the saved Recipe parameter names. Supported fields are
`x`, `y`, `width`, `height`, `rotation` and `seamAllowance`; lengths use
millimeters and rotation uses degrees. Curves retain their original node/edge
identities and use the existing element transform. Conflicting literal edits
return the binding and element identities; change the parameter or explicitly
update/remove that rule. Passing `null` removes the declarations.

Native controls and `form_update_object` resolve these same relationships.
Shared design variants retain their established shared-parameter behavior;
an independent iteration has its own controls. Updates remain one Undo
transaction. An assembly selection resolves its source controls, and the source
and assembled view use the same artwork, material coordinates and seam records.

`form_construction inspect`, `parameter` and `validate_cases` accept this source
object ID. Inspection returns `source_revision`; parameter edits may supply it
as `expected_revision`. Case validation uses an isolated snapshot and measures
actual stitch/cut contours, allowances, arc-length seam matches, declared rest
assemblies, material coordinates and attachment anchors. It leaves the accepted
source, history and selection intact. Reports give each case an explicit
outcome, including interrupted and unattempted cases. These checks do not
advance the cloth solver or establish calibrated fit.

Use smaller batches when the combined evidence budget rejects a request. The
existing capability response discloses supported properties, limits and outcome
names. The executable [source-authoring smoke](../scripts/smoke_artwork_parameters.py)
creates an unfamiliar curved sewn source, diagnoses and repairs failures, and
checks actual geometry, stable identities, Undo and reopen:

```sh
LAB_APP_PATH="$PWD/build/LAB.app" python3 scripts/smoke_artwork_parameters.py
```

Physical [inside-frame editing](sample-visual-validation.md) and trim/bleed/safe
guides are projections of those canonical sources. Derived views do not create
another editable artwork document.
