# AI object creation

This document records the product definitions established for AI-assisted object creation in Form.

- **Adding an object is an AI-enabled action.** The user clicks **Add Object**, enters what they want, and the object is added to the Table. This is the primary, nearly sole way to add new objects.

- **The input is freeform.** A request can be vague or detailed. The interface should support typing, voice input, and attaching references.

- **There is no normal conversational response after a successful add.** The agent does the work and the object appears on the Table.

- **The agent uses judgment.** It should make excellent guesses when it has enough information and ask the user questions whenever it needs more information or encounters a problem.

- **The scope is flexible.** Requests can cover merchandise, packaging, cut-and-sew products, a case around a Raspberry Pi, a lamp built around a KiCad board, and other objects. The app should not need a separately built-in creation feature for every object type.

- **Existing object-specific add controls and small primitives should go away as the primary user-facing way to add things.** A library may eventually offer another way to duplicate existing items.

- **The existing standard object library matters.** The agent should be able to consult a large private library of real-world, manufacturable objects to inform its work—for example, using excellent fabric flag references to create a standard flag.

- **Real product references can include a specific product and SKU.** That identity should be available in the object’s details or metadata; the agent should not announce its inspiration as a response.

- **A public, user-selectable library of blanks is a possible future feature**, but building it should not be required for AI object creation to work.

- **The generated object should use the app’s full capabilities.** For garments, that includes actual construction details such as pattern pieces, seams, hems, and stitches, with millimeter accuracy suitable for final production. Materials should affect the object appropriately, including its appearance.

- **The quality bar is extremely high.** The agent should use tools to create and edit geometry, capture views, compare the result against its sources, check differences and relevant frames, and repeat the process until the work is correct. The user expects this process to take time.

- **The agent needs access to information.** It must be able to search the web and use other available information sources; web access can be configurable and capabilities may vary by model.

- **The result is an editable object on the Table.** Exposed parameters can be changed directly; other changes can be requested from an agent. The precise editing interface and whether there is a persistent project-wide agent remain undecided and are outside the main add flow.

- **The underlying modeling approach remains open.** You haven’t decided whether the agent should usually copy a reference, construct a new object informed by it, or rely on highly parameterized models. The requirement is flexibility without having to hand-build every object category into the app.
