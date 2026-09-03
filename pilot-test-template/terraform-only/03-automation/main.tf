terraform {
  required_version = ">= 1.5"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 8.21"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }
}

provider "oci" {
  region              = var.ociRegionIdentifier
  auth                = var.ociAuthMethod
  config_file_profile = var.ociConfigProfile
}

resource "random_password" "generated" {
  for_each = setsubtract(var.generated_value_keys, nonsensitive(toset(keys(var.generated_value_overrides))))

  length      = 20
  special     = false
  min_upper   = 1
  min_lower   = 1
  min_numeric = 1
}

locals {
  res_id = var.resId != "" ? var.resId : "test"
  generated_values = merge(
    var.generated_value_overrides,
    { for key, password in random_password.generated : key => password.result }
  )
}

module "workshop_resources" {
  source = "../02-edit-if-needed/workshop"

  enabled = true
  context = {
    tenancy_ocid         = var.ociTenancyOcid
    user_ocid            = var.ociUserOcid
    compartment_ocid     = var.ociCompartmentOcid
    region               = var.ociRegionIdentifier
    resource_id          = local.res_id
    resource_name_prefix = var.resource_name_prefix
    tester_source_cidr   = var.tester_source_cidr
    vcn_ocid             = var.ociVcnOcid
    public_subnet_ocid   = var.ociPublicSubnetOcid
    private_subnet_ocid  = var.ociPrivateSubnetOcid
  }
  generated_values   = local.generated_values
  settings           = var.workshop_settings
  sensitive_settings = var.workshop_sensitive_settings
}
