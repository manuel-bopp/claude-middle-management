# Runbooks

Created: <YYYY-MM-DD HH:MM> · <model-id> · direct
Last updated: <YYYY-MM-DD HH:MM> · <model-id>

One file per repeatable procedure: deploys, restores, rotations, releases, incident drills. A
runbook is written so somebody who was not there can execute it — exact commands, exact paths, and
what the output looks like when it worked.

- **Name:** `<topic>.md`, lower case, one topic per file.
- **Shape:** when to run it · prerequisites · numbered steps with the literal commands · how to
  verify · how to roll back.
- **Third time → runbook.** A procedure explained or performed a third time gets a file here.
- Keep it current: the session that changes a procedure updates its runbook in the same wrap.

| Runbook | Covers |
|---------|--------|
| `<topic>.md` | <one line> |
