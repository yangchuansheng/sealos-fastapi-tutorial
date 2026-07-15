# Phase 22 PostgreSQL Evidence

This directory contains curated, credential-free output from one complete
real-PostgreSQL phase gate. Generated database passwords, Secret payloads,
tokens, namespace credentials, and credential-bearing URLs are excluded before
disk write.

| File | Scope | Reproduction command |
|------|-------|----------------------|
| `commands.txt` | Locked install, export, migration, tests, Job validation, and full-gate commands | Follow the commands in file order. |
| `migrations.txt` | Fresh and repeat Alembic upgrade at revision `0001` | `DATABASE_URL=<redacted> uv run alembic upgrade head` |
| `http.jsonl` | Health, Swagger UI, cross-instance CRUD, deletion, and stable 404 through public HTTP | `TEST_DATABASE_URL=<redacted> uv run pytest -q` |
| `jobs.txt` | Strict production manifest validation and two source Job `Complete` conditions | `./scripts/test-postgres.sh --jobs-only --state-file <state-file>` |
| `cleanup.txt` | Exact-label zero inventory and stopped owned port-forward | `./scripts/test-postgres.sh --assert-clean --state-file <state-file>` |
| `checksums.txt` | SHA-256 manifest over every retained evidence file above | `sha256sum -c evidence/phase-22/checksums.txt` |

The full reproduction command is:

```bash
PHASE22_EVIDENCE_DIR=evidence/phase-22 \
  ./scripts/test-postgres.sh --phase-gate
```
