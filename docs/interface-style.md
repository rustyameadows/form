# LAB interface style

LAB 0.5.1 uses SF system type for application labels, headings and controls. SF Mono is reserved for technical values, dimensions, code, identifiers and output metadata. Authored typography and font-browser samples continue to display their actual assigned faces.

Application surfaces are white, with black text, neutral gray secondary text and neutral workspace surrounds. Panels are opaque white. Rulers, grid lines, thumbnails, paper/sheet review, embroidery and cutting-layout surrounds, print-bed chrome and the default Table background follow the same neutral palette. The app icon is monochrome. Product materials, artwork, reference images, fabrication thread/filament colors and explicitly selected Studio presentation surfaces remain design content.

## One configurable accent

Open **LAB → Settings… → Appearance** with **⌘,**. Home also has an Appearance gear, and LAB Library links to the same settings window.

Choose a color with the native picker or enter a six-digit RGB hex value and press Apply. Changes appear live in controls, selected states, 2D editing handles and 3D selection outlines. Reset restores the default blue, `#245BFF`. Pale choices use a darker tone of the same hue so controls retain at least 4.5:1 contrast on white. Invalid hex input remains visible with an explanatory message and does not replace the saved preference.

The preference is local to the application and survives restarting it. It is stored in app defaults, separately from project files and the material/equipment library. Isolated libraries selected with `LAB_LIBRARY_PATH` use their own `Appearance.json`, so validation cannot change the ordinary app preference. Failed file persistence leaves the active accent unchanged.

Appearance refresh changes presentation only. It does not commit text, clear an open preparation or scene draft, move a camera, change geometry, recolor a material, or add a document Undo step. Camera navigation and bindings are unchanged.

Paper construction guides in the interactive review use solid black cuts, dashed gray creases and shaded glue regions. Their production SVG/PDF colors and roles retain the established output convention. Other authored proof content retains its own source colors.

## Review

The acceptance pass covers Home, Form Canvas/Table/split, Function on rigid and fabric objects, guided Fabricate, Studio, Appearance, project notes, the object/material library, print preparation, physical review and source-editing panels. See the [native acceptance record](evidence/interface-style-native.json) for the screen inventory, screenshots, test results and preservation checks. Standard macOS window controls, focus rings and native system panels retain their OS appearance.

## Known display issue found during review

The native Print preparation sheet shows a blank bed viewport on this Mac. The same isolated lamp fixture reproduces it in the preceding 0.5.0 release, before this style pass. Actual GPU capture contains the correct prepared object and bed; the display problem remains unresolved. The style update does not claim to repair it. Speculative viewport/lifecycle changes were removed. No slicing or hardware operation was used to investigate it.
