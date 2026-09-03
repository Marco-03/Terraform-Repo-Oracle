# OCI Image Terraform Projects

This public repository contains Terraform acceptance projects paired with image
bundles in `oracle-livelabs/demo-code` and `oracle-livelabs/livestack`. Clone the
repositories beside each other so the build launchers can resolve the matching
Terraform project by folder name:

~~~text
GitHub/
|- demo-code/
|- livestack/
`- Terraform-Repo-Oracle/
~~~

| Image bundle | Terraform project |
| --- | --- |
| `automated-build` | `pilot-test-template/custom-image` |
| `peak-gear-livestack` | `peak-gear-livestack` |
| `kevin-test-custom-image` | `kevin-test-custom-image` |

Keep local variable files, Terraform state, generated plans, automation receipts,
credentials, wallets, private keys, and complete PAR URLs out of Git. Create each
local `01-edit/terraform.tfvars` from its tracked `.example` file.
