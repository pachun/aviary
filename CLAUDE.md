@AGENTS.md

## Reproducible deployments

Make and test changes in the local checkout. For an authorized deployment,
commit and push the application changes and any required changes to
`~/code/depot`, then pull those commits on the NAS and rebuild using Depot's
checked-in configuration (or run `depot update aviary`).

Never deploy by copying uncommitted source files to the NAS, editing its source
checkout directly, or applying container-only fixes. Verify the NAS checkout
matches the pushed commit and is clean, then verify the running service.

Credentials and persistent data belong in the configured private storage on
the NAS, outside Git. Keep their setup and reconnect procedures reproducible
in Depot.
