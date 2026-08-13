# System architecture

Portal is a native macOS and iOS client that presents one product surface over multiple agent backends. The application is organized around the dependency direction documented in `docs/architecture-rules.md`:

**Models → Services → ViewModels → Views**

Dependencies point toward models and service contracts. Views render observable state and do not reach through a ViewModel to a concrete transport.

## Runtime actors

- **Portal application** owns presentation, local state, persistence, and backend selection.
- **Hermes Gateway** exposes the Ethen-managed WebSocket JSON-RPC runtime and full agent surface.
- **Hermes Standard** exposes upstream HTTP/SSE management APIs.
- **Centaur API** exposes REST/SSE chat and workflow behavior through a separate harness platform.
- **Device services** provide Keychain, files, notifications, media, and platform frameworks.

## Backend seam

`AgentBackend` is the backend-neutral interface consumed by chat orchestration. Concrete backends normalize their events into `GatewayEvent` and expose capabilities so unsupported behavior is hidden rather than failing at runtime.

Hermes and Centaur are distinct platforms behind this seam. A capability is evidence of supported behavior; it is not a request for the UI to emulate behavior the backend does not provide.

## Presentation domains

The primary product domains are chat, operations, wiki, living artifacts, and thought-graph exploration. Each domain may have presentation and orchestration nodes in the architecture graph. Shared models, services, and utilities remain visible as foundations rather than being duplicated under each feature.

## Artifact intent seam

Living artifacts are not only rendered; they can declare actions that dispatch real backend work. That contract is its own integration component rather than an implementation detail of artifact rendering, because it carries a security boundary: artifact-authored declarations and inert markup on one side, gateway-resolved handlers and native-only confirmation and navigation on the other.

Sessions author and revise artifacts; crons maintain them on a schedule. `artifact-intents` is where the dispatch, revision pinning, and maintainer references live. See `architecture/specifications/artifact-intents.md`.

## Wiki source seam

The wiki reads from knowledge backends whose capabilities are lopsided in both directions: one records edit history, the other reports page-edit volume, and both report an ingestion event log. `wiki-sources` holds the capability markers those surfaces gate on, so a wiki affordance appears because the source conforms rather than because the code recognized a backend. See `architecture/specifications/wiki.md`.

## Graph semantics

The interactive graph is a higher-order architectural map, not a raw file-import graph. Nodes represent components with a coherent responsibility. Edges represent meaningful compile-time or runtime relationships and retain source evidence. File and declaration inventories remain available as drill-down evidence.
