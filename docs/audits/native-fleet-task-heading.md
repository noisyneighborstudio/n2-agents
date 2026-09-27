# Accurate unfinished-task heading

The native task heading says `unfinished` for its existing nonterminal count.
Queued, running and unreachable tasks each contribute one. Completed tasks do
not contribute. The individual row still reports its specific lifecycle state.

The unchanged count and corrected production `FleetView.swift` component were
rendered at 360 points with the recorded adjacent JSON fixtures. Each single
nonterminal row displayed `1 unfinished`; their mixed fixture displayed
`3 unfinished`, excluding its completed row. Completed-only work had no count.
All five screenshots were inspected and retained in the sibling QA artifacts
`native-task-heading`, with source and image hashes in the JSON evidence.
The disposable renderer asserted those counts, then its code was discarded.
Independent review found no issue. No lifecycle or retry behavior changed.
