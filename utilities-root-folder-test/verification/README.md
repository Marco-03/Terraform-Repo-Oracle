# Post-deployment regression check

`utilities-livestack-regression.mjs` is an operator-run regression check
for a deployed Utilities LiveStack. It does not modify Utilities
business data.
Terraform and cloud-init never execute it automatically.

Run it from a workstation with Node.js 20 or later after the stack output
`first_boot_status_command` prints `RESOURCE_MANAGER_DEPLOYMENT_OK`:

```bash
node verification/utilities-livestack-regression.mjs \
  --base-url http://PUBLIC_IP:8505
```

The standard run checks the database-backed health endpoint, seeded data,
command center, vector, graph, spatial, OML, native Select AI, duality, and
reuse of an Oracle-created conversation ID across a two-turn Ask Utilities
follow-up. It
creates short-lived Select AI conversation records but does not invoke data
import/restore routes, rebuild OML models, or create Agent Console audit
actions.

To include the Agent Console two-turn follow-up check, add
`--include-agent-chat`. That optional check adds two normal chat audit records
to the demo database.

`UTILITIES_API_REGRESSION_OK` is the expected final marker. A nonzero exit code
or any `FAIL` line identifies the failing route.
