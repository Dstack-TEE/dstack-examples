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
| [`service-discovery-restructure.md`](service-discovery-restructure.md) | Move from `127.0.0.1:base+ordinal` to `service:port` UX via per-service VIPs (`127.10.0.0/24`) and per-peer VIPs (`127.50.0.0/24`). mesh-conn keeps a 3-port platform allowlist `{21000, 8300, 8301}`; all app traffic (including Patroni replication) goes through Envoy uniformly. Single rewrite, no staging — old impl rolls back via git. |
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
