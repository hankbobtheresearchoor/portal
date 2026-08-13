# Intent-based artifacts

A living artifact is not a rendered message. It is a named, persistent object the agent maintains across turns and sessions, and it may carry its own verbs. When it does, the artifact stops being a picture of a result and becomes a control surface: the user acts on the thing itself, and those actions reach the same agent harness that produced it.

The 3D world is the clearest case of this, because nothing about it looks like a form. A generated world is a `model3d` or `html` artifact rendered in a WebKit host. Its objects can carry declared bindings, so aiming at an object and clicking dispatches a backend intent — an ordinary agent session, or a registered handler. The same contract that puts a button on a dataset row puts an actionable object in a world.

## Why generation and steering are one system

An agent that can only emit a scene produces a picture. An agent that can emit a scene whose objects dispatch intents produces an interface it can also revise. Generation and steering therefore share one object, one revision counter, and one action manifest — not two subsystems that happen to reference each other.

This is what makes an artifact *living*: it accumulates revisions rather than being replaced, it can declare who tends it, and it can declare what may be done to it.

## Declaration, not code

An artifact never carries executable authority. It declares intents as data in an action manifest, and marks up its own presentation with inert attributes that name a declared binding.

- The declaration names a stable `binding_id`. The gateway resolves the registered handler from the pinned revision; the intent name travelling with the artifact is display and debugging material, never trusted as the thing to run.
- Page markup carries `data-hermes-binding` and an optional entity reference. It carries no script, no fetch, no credential, and no scheme URL.
- The host injects the only bridge that exists, in an isolated content world, gated by a per-view nonce. Synthetic clicks are ignored; a real user click is required to carry the capability.
- Confirmation for destructive intents is native chrome, led by the server-resolved intent name rather than the artifact's own label.

An artifact can therefore be authored by a model, or by a session, or by a cron, without any of them gaining the ability to register a handler. Authorship of declarations and authorship of executable handlers are deliberately separate powers.

## Dispatch tiers

Intent dispatch is tiered by what the work actually needs, and the tier is a review question rather than an author's preference:

1. **Local content mutation** — field edits and tombstones the client performs alone.
2. **Registered synchronous handlers** — deterministic operations whose code can be written in advance.
3. **Agent dispatch** — a contained agent run, for work that needs judgment because the behavior depends on the data.

If the code could be written in advance, it is not agent work. Agent dispatch is the escape hatch, not the default.

## Sessions and crons as artifact managers

Two kinds of agent time act on the same artifact, and the distinction between them is visible in the model.

**Sessions** author and revise. A session emits or upserts the artifact, and an intent may itself run as a contained session — in which case native chrome offers click-through into that run. The click-through is posted by native code; the untrusted page is never handed a session identifier or any navigation capability.

**Crons** maintain. Every artifact is mutable, because any writer may upsert it, but only some are *maintained* — tended on a schedule by a job that keeps the data current. An artifact declares its maintainers, so the product can distinguish "a job refreshes this every six hours" from "written once, now orphaned". That distinction is the reason the reference exists.

Together these make the artifact the durable object and agent time the thing that flows through it: a session brings a world into being, a cron keeps it true, and an intent declared on it sends the user's action back into the harness.

## Architectural consequence

Intent-based artifacts are a system, not a feature of one view. The contract spans domain declarations, the untrusted-content bridge, the store that pins revisions and dispatches invocations, and the surfaces that render actions and maintenance state. The architecture graph names that seam explicitly so the security-relevant boundary — declared data in, resolved handlers out, native-only confirmation and navigation — stays legible instead of being distributed silently across artifact rendering and shared models.
