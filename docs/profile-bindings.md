# Profile identity

`agents profiles --json` is a read-only description of N2 profile metadata. Each
row contains a display name, opaque `profileId`, `metadataStatus`, scope and the
local enrolled `machineId`. These are configuration identifiers, not evidence
of a provider account or available usage. An adapter must separately verify the
provider account and execution route before selecting it.

Named profiles carry a versioned `.n2-profile` marker. The ID survives repeated
sync and a directory rename. Deleting and creating a profile again generates a
new ID. Copying a profile directory also copies its ID; duplicate IDs in the
local registry are reported as `duplicate`, not as usable bindings. Independently
created profiles with the same display name receive different IDs and use the
existing fleet conflict workflow when they meet.

Default is machine-local. Its marker never crosses the fleet protocol, and its
binding is scoped by the enrolled machine ID. Two rows named Default do not
establish a shared profile or provider account.

## Initializing an existing fleet

After fleet enrollment, run `agents profiles --ensure-ids` on the machine whose
existing named profiles are to be propagated, then sync before initializing
legacy profiles independently on other machines. This operation writes metadata
only; it does not log in, move credentials or select accounts. It also creates a
local Default marker. Repeating it preserves existing IDs.

Ordinary manifests create IDs for new, unmarked local profiles. They preserve
legacy `n2-agents profile` markers, so upgrading two previously synchronized
machines does not independently generate conflicting IDs. The explicit
initialization replaces the legacy marker on one machine. Ordinary three-way
sync carries that replacement to peers whose markers still match the agreed
base. Conflicting edits remain conflicts. There is no guessed identity merge
based on a name or on matching credential bytes.

Live profile markers transfer before their child resources. A receiver refuses
child files for a named profile until a valid marker exists. If an older sender
sends child files first, it can retry them after its marker arrives. An
interrupted transfer therefore cannot leave a child-only directory which the
next manifest mistakes for a newly created local profile. Profile deletion
markers follow child removals and retain the existing local-data blockers.

## Status and compatibility

Consumers must require `metadataStatus == "ready"` as one prerequisite, alongside
verified provider identity and other eligibility checks. `missing`, `legacy`,
`invalid`, `conflicting` and `duplicate` are not usable automatic bindings.
Unknown marker schemas and malformed files stay untouched. The reader bounds
file size and refuses marker symlinks and nonregular files. The signed receiver
validates payloads before installing them. The child-file gate establishes local
metadata presence; existing per-resource sync consent still governs transfers.
It does not itself prove agreement on a source profile UUID. Profile-level adopted directory links
remain supported by N2's existing containment rules.

The JSON response has `schemaVersion: 1`. It does not yet expose a configuration
revision or a T3 binding. Those remain required follow-up work. These IDs also do
not prove that profiles with the same ID resolve to the same provider account on
every machine; account verification remains a separate requirement.
