# Design docs — open work, intentionally separate from the user-facing docs

This directory holds design briefs for **planned but not-yet-implemented**
work on `consul-postgres-ha`. Each doc is structured so an agent (or a
person) can pick it up cold and start implementing.

The user-facing docs (`README.md`, `ARCHITECTURE.md`, `FAILOVER.md`,
`PUBLISHING.md`, `ROBUSTNESS.md`) describe what's *shipping today*.
This directory describes what's *next*. They're intentionally
separated so a user landing on the example doesn't get a roadmap
in their face.

| Doc | What |
|---|---|
| [`single-sidecar.md`](single-sidecar.md) | Collapse the 5 platform-plumbing containers (`keepalive`, `bootstrap-secrets`, `mesh-conn`, `consul`, `sidecar`/Envoy) into one image with a small shell-init multi-process supervisor. Per-CVM container count: 8 → 3. |
| [`attestation-admission.md`](attestation-admission.md) | Use dstack TEE attestation as the mesh-conn admission credential, replacing/augmenting the shared TURN HMAC. Phased plan: per-app-id first, Consul-KV-rooted policy later. |

Each doc includes:

- The current state and why it falls short
- What "done" looks like
- A concrete approach with a code/structure sketch
- Risks + mitigations
- Open questions for the implementing agent
- Success criteria
- Hand-off instructions

When a doc's work lands, delete the doc (the implementation + the
user-facing docs are the surviving artifacts).
