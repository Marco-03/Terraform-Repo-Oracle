# Create And Test A Terraform-Only OCI Resource With Codex

Fill in what you already know and use `HELP_ME_DEFINE` where you need Codex to help define expected behavior or tests. Paste the complete prompt into a new project-specific Codex task, then pin that task. Use exact absolute paths. This workflow creates and tests OCI-managed resources directly; it does not use Packer, a custom image, or a demo-code project.

Do not include passwords, tokens, private keys, wallet contents, generated credentials, or other secrets.

~~~text
Implement and validate exactly one Terraform-only OCI resource test from the approved starter.

REQUIRED INPUTS

TERRAFORM_PLAY_ROOT = [exact absolute path to Terraform-Repo-Oracle]
PROJECT_NAME = [lowercase final target folder name]
OCI_RESOURCES = [ADB, Object Storage, or other managed resources; use HELP_ME_DEFINE if unsure]
RESOURCE_GOAL = [plain-language description of what should be created and why]
EXPECTED_BEHAVIOR = [what a user or system must be able to do afterward, or HELP_ME_DEFINE]
GENERATED_VALUES = [password or value names Terraform must generate, NONE, or HELP_ME_DEFINE]
PROJECT_PREREQUISITES = [required local clients, OCI session, and input artifacts, NONE, or HELP_ME_DEFINE]
SOURCE_INPUTS = [exact absolute ZIP, SQL, script, application, or configuration paths, or NONE]
SOURCE_INPUT_EXPECTATIONS = [required files, entrypoints, data, or structure inside each source, or HELP_ME_DEFINE]
PROVISIONING_TEST = [real login, query, upload, API call, or behavior that proves success, or HELP_ME_DEFINE]
PASS_CONDITIONS = [specific observable results that must pass, or HELP_ME_DEFINE]
FAILURE_CASES = [important bad states the test must catch, or HELP_ME_DEFINE]
ADDITIONAL_REFERENCE_PATHS = [exact absolute files/folders that may be read, or NONE]
LOCAL_TERRAFORM_VALUES_SOURCE = [exact ignored Terraform variable file to consult read-only, or MANUAL]
RUN_FULL_TEST = [NO for implementation plus no-cloud validation, or YES to create and test temporary OCI resources]
VALIDATION_SCOPE = [FOCUSED unless an exhaustive inventory is explicitly required]

AUTHORITATIVE CONTEXT

Resolve these paths directly. Do not search for alternatives:

TARGET_TERRAFORM_FOLDER = TERRAFORM_PLAY_ROOT/PROJECT_NAME
TERRAFORM_ONLY_TEMPLATE = TERRAFORM_PLAY_ROOT/pilot-test-template/terraform-only
TERRAFORM_ONLY_GUIDE = TERRAFORM_ONLY_TEMPLATE/README.md
TERRAFORM_ROOT_GUIDE = TERRAFORM_PLAY_ROOT/pilot-test-template/README.md
DEMO_CODE_ROOT = TERRAFORM_PLAY_ROOT/../demo-code
WORKSPACE_INSTRUCTIONS = TERRAFORM_PLAY_ROOT/../AGENTS.md
WORKSPACE_MEMORY = TERRAFORM_PLAY_ROOT/../.codex/memory.md
WORKSPACE_MISTAKES = TERRAFORM_PLAY_ROOT/../.codex/mistakes.md

Read TERRAFORM_ONLY_GUIDE first. It defines the project layout, edit boundary, generated values, preflight checks, provisioning tests, ignored files, commands, cleanup behavior, and success criteria. Read TERRAFORM_ROOT_GUIDE second for the two-workflow boundary. These READMEs are authoritative for this task.

HARD SCOPE RULES

1. Read only the workspace instruction/memory files when present, the two authoritative guides, their explicitly listed template files, TARGET_TERRAFORM_FOLDER, SOURCE_INPUTS, ADDITIONAL_REFERENCE_PATHS, and LOCAL_TERRAFORM_VALUES_SOURCE without printing it.

2. Do not enumerate or recursively search DEMO_CODE_ROOT, a user home folder, a drive root, or the complete demo-code repository. Every search, file listing, and Git command must name an allowed target, template, or reference path explicitly.

3. Do not inspect demo-code, Packer, custom-image projects, similar workshops, alternate templates, skills, plugins, OCI examples, or unrelated documentation. Do not browse the web, download optional assets, or delegate to subagents.

4. If a required input or canonical path is missing, stop before editing and ask exactly one concise question. Do not widen the search.

5. Work only inside TARGET_TERRAFORM_FOLDER. Treat the template, source inputs, references, and local variable source as read-only.

6. Do not commit, push, create a pull request, or create OCI resources unless explicitly requested. RUN_FULL_TEST controls only the documented temporary resource test.

REQUIREMENTS AND TEST DESIGN GATE

1. Treat RESOURCE_GOAL and EXPECTED_BEHAVIOR as the user's intent. Do not expect the user to design Terraform tests.

2. When any field is HELP_ME_DEFINE, ask one focused plain-language question at a time. Ask what must work, what source content is expected, what result matters to users, and which incorrect outcomes would make the Green Button provisioning unacceptable.

3. Inspect only the explicitly supplied SOURCE_INPUTS before proposing implementation. For archives, verify that the archive opens safely, contains no unsafe paths, and includes the expected entry files. For scripts or configuration, identify placeholders, required tools, obvious error markers, and assumptions. Do not claim that static inspection proves runtime behavior.

4. Present a short TEST CONTRACT containing:
   - resource and plain-language goal;
   - expected behavior after provisioning;
   - source-artifact preflight checks;
   - provisioning action;
   - real post-apply acceptance tests;
   - specific pass conditions;
   - failure cases the tests will catch;
   - prerequisites, protected values, and cleanup behavior.

5. Stop and ask the user to approve or correct the TEST CONTRACT before copying the template, editing Terraform, or implementing tests. Do not create OCI resources during this design gate.

6. Tests are only as complete as the approved contract. Resource creation, a successful Terraform exit code, or non-empty data alone is not sufficient unless the contract explicitly says that is enough.

FIXED EXECUTION SEQUENCE

1. Confirm the TEST CONTRACT is approved. Then confirm TERRAFORM_ONLY_TEMPLATE exists and TARGET_TERRAFORM_FOLDER has PROJECT_NAME as its final name. Confirm the request needs no Compute image VM or container runtime. Stop with one question if it belongs in the custom-image workflow instead.

2. Read TERRAFORM_ONLY_GUIDE first and TERRAFORM_ROOT_GUIDE second before editing.

3. If the target does not exist, copy only tracked files from TERRAFORM_ONLY_TEMPLATE. Never copy ignored variables, `.terraform`, state, plans, `.automation`, generated values, wallets, logs, credentials, session tokens, private keys, or personal paths.

4. Inspect only:
   - TARGET_TERRAFORM_FOLDER/01-edit/terraform.tfvars.example
   - TARGET_TERRAFORM_FOLDER/02-edit-if-needed/workshop
   - TARGET_TERRAFORM_FOLDER/02-edit-if-needed/provisioning-tests

5. Do not inspect or edit `03-automation` for a normal resource test. Run it as documented. Inspect shared automation only when validation identifies a specific resource-neutral defect independent of this project.

6. Implement only the required OCI resources under `02-edit-if-needed/workshop`:
   - use `var.context` for OCI location and reservation values;
   - use `var.generated_values` for generated passwords or values;
   - expose safe names and OCIDs through `resource_summary`;
   - expose only test-required sensitive values through `resource_test_context`;
   - keep resource-specific clients, loaders, scripts, and fixes inside the copied project.

7. Add `preflight-*.ps1` when a local client, OCI session, permission, or source artifact must be checked before Terraform creates resources. Validate every approved SOURCE_INPUT_EXPECTATION that can be checked without creating OCI resources. Fail early for a missing or unreadable artifact, unsafe archive path, missing entrypoint, unresolved placeholder, or missing required client.

8. Add at least one `test-*.ps1` that proves PROVISIONING_TEST after apply. Resource creation or an exit code alone is not enough. Use focused real logins, queries, API calls, uploads, downloads, or outputs that directly prove PASS_CONDITIONS and exercise the approved FAILURE_CASES where safe.

9. Keep project scripts portable across Windows PowerShell 5.1 and PowerShell 7 on Linux or macOS. Use `Join-Path`, `Get-Command`, argument arrays, and temporary paths. If Terraform must invoke an external script, use a cross-platform executable or provide operating-system-specific implementations in the copied project.

10. Create ignored `01-edit/terraform.tfvars` from the example. Reuse only relevant OCI identifiers, profile names, safe network values, and resource sizing from an exact supplied source. Never copy generated secrets, state, wallets, plans, or stale tester addresses.

11. Use only the minimum network access required by the resource. When tester ingress is needed, require the current public IPv4 as `/32`. Never use `0.0.0.0/0` or `::/0` unless explicitly approved.

12. Run the documented `-ValidateOnly` command from TARGET_TERRAFORM_FOLDER. It must check Terraform formatting/validation, project tests, placeholders, and prerequisites without creating OCI resources.

13. If RUN_FULL_TEST is NO, stop after validation and return the exact apply command. If RUN_FULL_TEST is YES, review the plan inputs, remain with the run through provisioning tests and cleanup, and require `RESOURCE PROVISIONING TEST PASSED`.

14. A failed run may preserve its isolated workspace and resources for inspection. Report the exact cleanup command and do not delete its state first.

15. Scope all status, diff, and secret checks to TARGET_TERRAFORM_FOLDER. Do not report unrelated repository changes.

FINAL RESPONSE

Keep the response short and include only:
- target folder and OCI resource type;
- files changed;
- what the provisioning test proves;
- validation or full-test result;
- cleanup status;
- missing manual values, if any;
- one exact next command from TARGET_TERRAFORM_FOLDER.
~~~

## Expected Commands

Windows:

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\03-automation\test-resources.ps1 -ValidateOnly
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\03-automation\test-resources.ps1 -Apply
~~~

Linux or macOS:

~~~bash
bash ./03-automation/test-resources.sh -ValidateOnly
bash ./03-automation/test-resources.sh -Apply
~~~
