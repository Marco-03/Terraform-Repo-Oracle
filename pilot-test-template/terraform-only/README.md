# Terraform-Only Resource Test Template

Copy this folder when the thing being tested is an OCI-managed resource and no custom Compute image is required.

Typical examples:

- Autonomous Database and an SQL loader
- Object Storage
- Vault or another managed OCI service
- A provisioning step that Terraform can create and a local client can verify

An endpoint does not automatically mean custom image. ADB has an endpoint but still uses this template. A Jupyter container uses the custom-image template because it needs a VM runtime.

## Use The Terraform-Only Prompt

Before copying or editing the starter, fill [CREATE-TERRAFORM-ONLY-PROMPT.md](CREATE-TERRAFORM-ONLY-PROMPT.md) and paste it into the pinned Codex task for that project. The prompt reads this README first as the authoritative context and limits work to the exact target folder and supplied source paths.

Create one Codex task for the copied resource-test project, name it after the project, and pin it. Use that task for configuration, validation, test runs, failure investigation, and cleanup so it retains the correct resource context. Do not paste secrets, wallets, generated passwords, or complete PAR URLs into it.

## Start With The Desired Behavior

The resource owner explains the outcome in plain language; they do not need to invent Terraform tests. In [CREATE-TERRAFORM-ONLY-PROMPT.md](CREATE-TERRAFORM-ONLY-PROMPT.md), use `HELP_ME_DEFINE` for any testing field that is unclear.

Example:

~~~text
OCI_RESOURCES = Autonomous Database
RESOURCE_GOAL = Create an ADB and load the supplied workshop SQL package
EXPECTED_BEHAVIOR = HELP_ME_DEFINE
SOURCE_INPUTS = C:/approved-inputs/workshop-loader.zip
SOURCE_INPUT_EXPECTATIONS = HELP_ME_DEFINE
PROVISIONING_TEST = HELP_ME_DEFINE
PASS_CONDITIONS = HELP_ME_DEFINE
FAILURE_CASES = HELP_ME_DEFINE
~~~

Codex must then ask focused questions and propose a **test contract** before editing. The contract states what the resource should do, what must exist in supplied files, what can fail before provisioning, what real behavior will be tested after apply, and the exact pass conditions. Review and approve that contract before implementation.

Why: Codex can translate expected behavior into checks, but it cannot decide what correct workshop behavior means without the resource owner's input. A Terraform success message proves only that Terraform completed; it does not prove that a loader, configuration, login, data set, or API works correctly.

## Step 1: Copy The Template

Copy this folder to a new project at the root of `Terraform-Repo-Oracle`:

Windows:

~~~powershell
Copy-Item -Recurse .\pilot-test-template\terraform-only .\my-resource-test
Set-Location .\my-resource-test
~~~

Linux or macOS:

~~~bash
cp -R ./pilot-test-template/terraform-only ./my-resource-test
cd ./my-resource-test
~~~

Why: every resource test gets its own code, variables, state, and cleanup boundary.

Do not copy ignored variables, state, plans, credentials, or `.terraform` from another project.

## Step 2: Fill The OCI Variables

Windows:

~~~powershell
Copy-Item .\01-edit\terraform.tfvars.example .\01-edit\terraform.tfvars
notepad .\01-edit\terraform.tfvars
~~~

Linux or macOS:

~~~bash
cp ./01-edit/terraform.tfvars.example ./01-edit/terraform.tfvars
${EDITOR:-vi} ./01-edit/terraform.tfvars
~~~

Fill the tenancy, compartment, region, and OCI profile. Fill VCN, subnet, and tester CIDR only when the resource needs them.

Why: Terraform needs to know exactly where it may create the temporary test resource.

There is no mode toggle, Packer file, image OCID, SSH key, or Compute VM configuration in this template.

## Resource-Specific And Cross-Platform Rule

`03-automation/` only orchestrates Terraform, protected context, tests, and cleanup. Do not add SQLcl, database logic, Object Storage logic, or another service-specific fix to the shared starter.

Put each resource's provider configuration in `02-edit-if-needed/workshop/` and its real behavior checks in `02-edit-if-needed/provisioning-tests/`. Install and preflight only the client that project needs, such as SQLcl for ADB, OCI CLI for a service-state check, or an HTTP client for an endpoint.

Provisioning tests must run in Windows PowerShell 5.1 and PowerShell 7 on Linux or macOS. Use `Join-Path`, `Get-Command`, argument arrays, and temporary paths. Do not hardcode `C:\`, `/Users/`, `powershell.exe`, `cmd.exe`, or `/bin/bash`. If real Terraform provisioning must call an external script, use a cross-platform executable or provide both operating-system implementations inside that copied project; do not put the service implementation in the starter.

## Step 3: Add The Resource

Edit `02-edit-if-needed/workshop/main.tf`.

When adapting existing Terraform:

1. Move only the required resource logic into this module.
2. Replace fixed tenancy or compartment values with `var.context` values.
3. Use `var.settings` for non-secret project choices.
4. Use `var.generated_values` for generated passwords.
5. Keep every resource guarded by `var.enabled`.
6. Do not copy Terraform state, ignored files, user API keys, or unrelated resources.

Populate `resource_summary` with safe names or OCIDs that may be printed. Populate `resource_test_context` with only the connection information and credentials required by tests.

Why: the runner prints the safe summary but stores the sensitive context in a protected temporary file.

## Step 4: Add Project Preflight And A Real Test

If the project needs a local client or input artifact, copy the optional preflight example:

~~~powershell
Copy-Item .\02-edit-if-needed\provisioning-tests\preflight-resource.ps1.example `
  .\02-edit-if-needed\provisioning-tests\preflight-my-resource.ps1
~~~

Use it to check project prerequisites and every approved source expectation that can be tested locally. For example: confirm the required CLI is installed, an archive opens, archive paths are safe, expected entry files exist, required placeholders are resolved, and the local login session is valid. The shared runner executes every `preflight-*.ps1` file before Terraform initializes or creates resources. Static checks cannot prove that SQL, an API call, or another workload will execute correctly against the real OCI service; the post-apply test must prove that behavior.

Why: a missing client or bad local input should fail in seconds, not after OCI has created a resource.

Copy the behavior-test example:

~~~powershell
Copy-Item .\02-edit-if-needed\provisioning-tests\test-resource.ps1.example `
  .\02-edit-if-needed\provisioning-tests\test-my-resource.ps1
~~~

Replace the TODO with the approved real behavior checks. The client and assertions depend on the copied project: for example, authenticate to a database, verify required records and values, upload and read an object, call an API, or confirm a generated value works. Include checks for the contract's important failure cases; a non-empty table or successful exit code may be too weak.

Why: successful resource creation alone does not prove that the resource works.

Preflight scripts receive:

~~~text
-ProjectRoot <this project>
~~~

Post-apply tests receive:

~~~text
-TestContextFile <protected JSON>
-ProjectRoot <this project>
-WaitSeconds <timeout>
~~~

Keep all resource-specific dependencies and fixes in this copied project. Never print passwords, tokens, wallets, or the complete test context.

## Step 5: Validate Without Creating Resources

Windows:

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\03-automation\test-resources.ps1 -ValidateOnly
~~~

Linux or macOS:

~~~bash
bash ./03-automation/test-resources.sh -ValidateOnly
~~~

Why: this catches Terraform, input, and test-script errors before OCI resources cost time or money.

## Step 6: Create, Test, And Clean Up

Windows:

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\03-automation\test-resources.ps1 -Apply
~~~

Linux or macOS:

~~~bash
bash ./03-automation/test-resources.sh -Apply
~~~

The runner creates an isolated workspace, reviews the plan for project resources, applies it, passes protected context to every test, destroys successful test resources, and deletes the workspace.

A successful run ends with:

~~~text
RESOURCE PROVISIONING TEST PASSED
~~~

It never claims Marketplace readiness.

## Failure Cleanup

A failed or deliberately retained run preserves its isolated workspace. Use the workspace name printed by the runner:

Windows:

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\03-automation\test-resources.ps1 `
  -CleanupWorkspace "resource-test-YYYYMMDDHHMMSS-PID"
~~~

Linux or macOS:

~~~bash
bash ./03-automation/test-resources.sh \
  -CleanupWorkspace "resource-test-YYYYMMDDHHMMSS-PID"
~~~

Do not delete state before cleanup. Terraform state contains generated secrets and is required to destroy the resources it owns.

## What This Does Not Prove

This test proves the Terraform resource, generated-value flow, and declared provisioning behavior tests. It does not prove LL Admin mapping or the final Green Button sandbox invocation.
