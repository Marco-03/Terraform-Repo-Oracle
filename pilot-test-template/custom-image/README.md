# Custom Image Terraform Template

Copy this folder when the workshop needs a Compute VM built from a reusable custom image. One container is enough to require this template.

The complete paired-folder workflow is documented in
`demo-code/imagebuild/automated-build/ALL-IN-ONE.md`.

Typical examples:

- Jupyter
- Ollama
- A web application
- A local database container
- Several containers started together with Compose

ADB is not part of the image. Test ADB with the sibling `terraform-only` template.

## Use The Custom-Image Prompt

Before copying or editing either project, fill `demo-code/imagebuild/automated-build/01-image-build/CREATE-CUSTOM-IMAGE-PROMPT.md` and paste it into the pinned Codex task for that project. That prompt reads the paired demo-code README first and this README second, then limits work to the exact target folders.

Create one Codex task for the copied image project, name it after the project, and pin it. Keep configuration, validation, build, inspection, and cleanup work in that task so later runs retain the correct project context. Do not paste secrets or complete PAR URLs into it.

## Copy It

Create one project folder at the root of `Terraform-Repo-Oracle` for the image. Give it the same final name as the paired image bundle.

~~~text
demo-code/imagebuild/<group>/my-project/
Terraform-Repo-Oracle/my-project/
~~~

Copy the contents of this template into `Terraform-Repo-Oracle/my-project`. Do not copy the ignored local `terraform.tfvars`, state, cache, plans, or `.automation` files from this starter.

## Fill The Local Variables

From the copied project:

~~~powershell
Copy-Item .\01-edit\terraform.tfvars.example .\01-edit\terraform.tfvars
notepad .\01-edit\terraform.tfvars
~~~

Fill the tenancy, compartment, region, public subnet, SSH public key, OCI profile, current tester `/32`, and the VM size chosen for the application. The file is ignored by Git. The template does not recommend a VM size.

There is no workflow toggle in this template.

## Build And Test

Run from the paired demo-code project, not from this Terraform folder.

Windows:

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\03-automation\build-and-test.ps1 -ImageName "my-image"
~~~

Linux or macOS:

~~~bash
bash ./03-automation/build-and-test.sh -ImageName "my-image"
~~~

The demo-code pipeline finds the matching Terraform folder automatically. It passes the Packer-created image OCID to `03-automation/test-custom-image.ps1`.

The test launches a clean VM, supplies fresh Terraform metadata, checks every declared service and endpoint, reboots, checks again, and destroys successful test resources.

A successful run ends with `READY FOR MARKETPLACE` and an ignored sanitized receipt in the demo-code project. A person then inspects and approves that exact image. The separate Marketplace template automates draft preparation and private-package testing; Oracle review submission and public publication remain human actions.

## What To Edit

| Path | Edit it for |
| --- | --- |
| `01-edit/terraform.tfvars` | Real local OCI values and VM sizing. |
| `02-edit-if-needed/metadata/main.tf` | Only special metadata generation or output behavior. |
| `03-automation/` | Shared image test machinery; do not edit for a normal image. |

Container, endpoint, dashboard, and service-test changes belong in the paired demo-code project. Read `demo-code/imagebuild/automated-build/01-image-build/README.md` before changing those files.
