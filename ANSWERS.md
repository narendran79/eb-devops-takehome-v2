# Q1 — Migrating ~40 Ingresses from ingress-nginx to Gateway API with no downtime

**Principle:** run old and new side by side, move traffic gradually, keep a rollback path until the end.

**Order**
1. List all 40 Ingresses and every annotation in use.
2. Install ingress-nginx with its own load balancer IP. Install Gateway API CRDs (pin the version) in a non-prod cluster first.
3. Use `ingress2gateway` for a first draft, then review. Map annotations to HTTPRoute filters or the implementation's policy CRDs.
4. Keep ingress-nginx running for a couple of days as rollback, then remove it.

**What I expect to break**
- certificates config changes.
- Defaults: timeouts, max body size, buffering and client-IP preservation
- Cross-namespace backends.
- Monitoring: metric names change, so dashboards and alerts need rebuilding before cutover.
