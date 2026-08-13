# The wiki as a knowledge system

A wiki in Portal is not a document viewer pointed at a folder of markdown. It is a knowledge base something else is actively writing: ingestion pipelines turn pull requests, tickets, documents, chat directives and usage rollups into raw *events*, and agents turn those events into typed, wikilinked pages. The client's job is to make both halves legible — the pages, and where they came from.

That split is why the wiki has an events surface at all. A page reader alone answers "what does the wiki say"; only the event log answers "on what evidence, and how recently".

## One surface, not a set of screens

The graph *is* the wiki home. There is no separate index page: with nothing selected the surface is a full-bleed force-directed graph, and selecting a page opens the reader over a graph that stays alive underneath it. The folder tree, the changeset drawer and the reader are all presentations layered on that one surface, sharing one selection plane, so a node highlight, a sidebar row and the open page can never disagree about what is being read.

The rendering choice — a 2D canvas or a SceneKit 3D layout — is a toggle on that one surface rather than a second mode with its own state.

## Capability markers, not backend checks

Two knowledge backends sit behind the same UI: the Hermes gateway's `wiki.*` RPCs and a REST wiki-api. They do not serve the same things, and the difference is expressed as protocol conformance rather than a backend-kind branch:

- **`WikiSource`** is the floor — fetch the graph, fetch a page. Every backend has it.
- **`WikiChangesetSource`** marks a backend that records edit history. The timeline drawer with its git-style inline diffs shows only for sources that conform; today that is the gateway alone.
- **`WikiEventLogSource`** marks a backend that can say what flowed *in*. The event plot and feed gate on this, and both backends have it.
- **`WikiEventTimelineProviding`** marks a backend that also serves bucketed page-edit volume, a pre-window revision baseline and a pages-touched summary. Only the REST backend has these, so the "knowledge accrued" pane is enrichment that appears when the source supports it.

The capabilities are genuinely lopsided in both directions — the gateway has the edit history the REST backend lacks, the REST backend has the volume rollups the gateway lacks — which is precisely why none of this can be a backend-kind branch. There is no "richer" backend to privilege.

The distinction between the last two markers is the load-bearing one, and it is why they are separate protocols rather than one: splitting the event log out is what lets the plot and feed serve both backends while the accrued pane stays optional. A surface that gated on the wider protocol would have hidden the event log from a backend that has one.

This is the same principle as the `AgentBackend` seam for chat: a capability is evidence of supported behavior, never a request to emulate what a backend cannot do. A view asks whether the source conforms; it never asks which backend it is talking to.

## Fields that are absent, not faked

Both backends fill one row type, and each side leaves the other's enrichment nil or empty rather than inventing it. Directive attribution — who asked for a change, in what words — is REST-only. The event → changeset → page edge is gateway-only, reported off one index read so provenance can be walked without a second round trip. Every view that shows either checks first, so a missing affordance means the backend has nothing to show rather than a bug.

The same honesty applies to time. An event carries both an event time and an ingest time, and a flag for the case where the pipeline only ever knew the latter. Those events are still real — the feed lists them and the legend counts them — but a plot has no x for them, so the surface counts what it left out instead of quietly dropping it. An event whose timestamp falls outside the requested window is counted too: the client's window and the server's filtering can disagree, and saying so is what turns "the plot is empty" into "these events sit outside this window".

## Input against output

Ingestion volume and page-edit volume are different measures, so they are never dual-axed onto one plot. They are drawn as separate charts sharing one time domain, bucketed to the same unit the server chose, and the shared x-axis carries the correlation. The cumulative curve seeds from the pre-window revision count so its height is true rather than restarting at zero for the window being viewed.

## Architectural consequence

The wiki spans presentation (`wiki-ui`), its own orchestration state (`wiki-state`), and fetch surfaces that live with each transport. What the graph cannot show is that the capability protocols — not the backend identity — are the seam. Adding a third knowledge backend means conforming to the markers it can honor, and the surfaces it grows follow from that alone.
