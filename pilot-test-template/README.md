# OCI Workshop Test Pilot: Terraform Play

This folder contains two independent starters. Copy one starter into a new project at the root of `Terraform-Repo-Oracle`; do not edit or run the starter in place.

| Test | Starter | Result |
| --- | --- | --- |
| Containers, VM software, or reusable custom image | `custom-image/` | `READY FOR MARKETPLACE` |
| OCI-managed resource such as ADB or Object Storage | `terraform-only/` | `RESOURCE PROVISIONING TEST PASSED` |

ADB uses Terraform-only even though it has an endpoint. Jupyter, Ollama, web applications, and local database containers use custom-image because they require a Compute VM.

## Choose The Correct Prompt

Use the prompt stored beside the selected starter README. Each prompt tells a project-specific Codex task to read that same-folder README first and forbids broad workspace searches.

| Need | Prompt |
| --- | --- |
| Compute VM, containers, installed software, or reusable image | `demo-code/imagebuild/automated-build/01-image-build/CREATE-CUSTOM-IMAGE-PROMPT.md` |
| OCI-managed resource with no image VM | [terraform-only/CREATE-TERRAFORM-ONLY-PROMPT.md](terraform-only/CREATE-TERRAFORM-ONLY-PROMPT.md) |

Use a fresh filled prompt for every project so paths and local values from an older project are not reused. Keep passwords, tokens, private keys, wallet contents, and generated credentials out of chat and tracked files.

### Keep One Pinned Codex Task Per Project

Create one Codex task for each copied image or resource test, paste the matching prompt into it, give the task the project name, and pin it. Use that pinned task as the normal place to configure variables, add resources or services, run validation, investigate failures, and clean up preserved workspaces. Keeping one task per project prevents paths and assumptions from leaking between tests. Never paste credentials, private keys, security tokens, wallet files, generated passwords, or complete PAR URLs into the task.

## One-Time Setup

1. Clone `Terraform-Repo-Oracle` beside `demo-code` and `livestack`. All local Terraform test projects are stored at the root of this repository.
2. Install OCI CLI and Terraform. Custom-image projects also require Packer, OpenSSH, curl, and Python; their macOS and Linux launchers are native. The current Terraform-only launcher requires PowerShell 7 on macOS or Linux. Install SQLcl, a service SDK, or another client only when the selected resource test requires it.
3. Create and validate an OCI browser-login profile. The name is arbitrary:

~~~powershell
oci session authenticate --profile-name WORKSHOP_TEST --region us-ashburn-1
oci session validate --profile WORKSHOP_TEST
~~~

4. Obtain permission to create and delete the selected resources in the target compartment.
5. Copy the compartment OCID from OCI Console. Get the current public IP with `curl.exe https://api.ipify.org` on Windows or `curl https://api.ipify.org` on Linux or macOS. Use only `<ip>/32`, never `0.0.0.0/0`.
6. Collect project-specific inputs such as an approved SQL file, model URL, image OCID, subnet, SSH key, or expected behavior.

## Start A Project

For a custom image, copy `custom-image/` to `Terraform-Repo-Oracle/my-project/` and create the same final folder name under `demo-code/imagebuild/`. Follow [custom-image/README.md](custom-image/README.md).

For one OCI-managed resource, copy `terraform-only/` to `Terraform-Repo-Oracle/my-resource-test/`. No demo-code folder or Packer configuration is needed. Follow [terraform-only/README.md](terraform-only/README.md).

Inside the copied project:

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

Fill the tenancy, compartment, region, profile, current `/32`, and resource-specific values. With security-token authentication, `ociUserOcid` may remain empty. Keep generated-password overrides empty unless a repeatable fixed-value test explicitly requires them.

The real `terraform.tfvars`, Terraform state, plans, `.terraform`, `.automation`, generated passwords, wallets, and credentials are ignored. Never commit or copy them between projects.

## Run Terraform-Only

Validate without creating resources:

~~~powershell
# Windows
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\03-automation\test-resources.ps1 -ValidateOnly
~~~

~~~bash
# Linux or macOS
bash ./03-automation/test-resources.sh -ValidateOnly
~~~

After reviewing the inputs, create the resource, run its real provisioning tests, and clean up:

~~~powershell
# Windows
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\03-automation\test-resources.ps1 -Apply
~~~

~~~bash
# Linux or macOS
bash ./03-automation/test-resources.sh -Apply
~~~

A failed run preserves its isolated workspace and prints the exact `-CleanupWorkspace` command. Run that command before retrying; do not delete the state first.

Custom-image tests are launched from the paired demo-code folder. Their pipeline passes the Packer image OCID to Terraform, tests a clean VM before and after reboot, and removes successful test infrastructure.
