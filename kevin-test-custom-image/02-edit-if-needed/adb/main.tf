terraform {
  required_providers {
    local = {
      source  = "hashicorp/local"
      version = "~> 2.6"
    }
    oci = {
      source  = "oracle/oci"
      version = "~> 8.21"
    }
  }
}

variable "context" {
  type = object({
    compartment_ocid     = string
    region               = string
    resource_id          = string
    resource_name_prefix = string
  })
}

variable "admin_password" {
  type      = string
  sensitive = true
}

variable "compute_count" {
  type = number
}

variable "storage_tbs" {
  type = number
}

variable "db_version" {
  type = string
}

variable "datapump_enabled" {
  type = bool
}

variable "datapump_dump_uris" {
  type      = list(string)
  sensitive = true
}

variable "datapump_encryption_password" {
  type      = string
  sensitive = true
}

variable "datapump_credential_name" {
  type = string
}

variable "datapump_credential_username" {
  type      = string
  sensitive = true
}

variable "datapump_credential_password" {
  type      = string
  sensitive = true
}

variable "datapump_source_schema" {
  type = string
}

variable "datapump_target_schema" {
  type = string
}

locals {
  # Workspace hashing makes retry databases unique without exposing a name choice.
  database_name = "ADB${upper(substr(sha1(terraform.workspace), 0, 10))}"
  service_name  = "${local.database_name}_high"
  wallet_path   = "${path.root}/.automation/${terraform.workspace}-adb-wallet.zip"
  datapump_path = "${path.root}/.automation/${terraform.workspace}-lanl-datapump.json"
  database_host = "adb.${var.context.region}.oraclecloud.com"
}

resource "oci_database_autonomous_database" "pilot" {
  admin_password              = var.admin_password
  compartment_id              = var.context.compartment_ocid
  compute_model               = "ECPU"
  compute_count               = var.compute_count
  data_storage_size_in_tbs    = var.storage_tbs
  db_name                     = local.database_name
  db_version                  = var.db_version
  db_workload                 = "OLTP"
  display_name                = "${var.context.resource_name_prefix}-${var.context.resource_id}-adb"
  is_auto_scaling_enabled     = false
  is_free_tier                = false
  is_mtls_connection_required = true
  license_model               = "BRING_YOUR_OWN_LICENSE"

  freeform_tags = {
    CreatedBy = "oci-image-pilot"
    Purpose   = "temporary-adb-image-test"
  }

  lifecycle {
    precondition {
      condition     = can(regex("^[A-Z][A-Z0-9]{0,13}$", local.database_name))
      error_message = "The generated ADB name is invalid."
    }
    precondition {
      condition     = can(regex("^[A-Za-z0-9]{12,30}$", var.admin_password))
      error_message = "The generated ADB administrator password must be 12-30 alphanumeric characters."
    }
  }
}

resource "oci_database_autonomous_database_wallet" "pilot" {
  autonomous_database_id = oci_database_autonomous_database.pilot.id
  base64_encode_content  = true
  generate_type          = "SINGLE"
  password               = var.admin_password
}

resource "local_sensitive_file" "wallet" {
  content_base64       = oci_database_autonomous_database_wallet.pilot.content
  filename             = local.wallet_path
  file_permission      = "0600"
  directory_permission = "0700"
}

resource "local_sensitive_file" "datapump" {
  count = var.datapump_enabled ? 1 : 0

  content = jsonencode({
    enabled             = true
    dump_uris           = var.datapump_dump_uris
    encryption_password = var.datapump_encryption_password
    credential_name     = upper(var.datapump_credential_name)
    credential_username = var.datapump_credential_username
    credential_password = var.datapump_credential_password
    source_schema       = upper(var.datapump_source_schema)
    target_schema       = upper(var.datapump_target_schema)
  })
  filename             = local.datapump_path
  file_permission      = "0600"
  directory_permission = "0700"
}

output "instance_metadata" {
  value = {
    adb_host           = local.database_host
    adb_service        = local.service_name
    adb_user           = upper(var.datapump_target_schema)
    adb_password       = var.admin_password
    adb_admin_user     = "ADMIN"
    adb_admin_password = var.admin_password
  }
  sensitive = true
}

output "admin_user" {
  value = "ADMIN"
}

output "workshop_user" {
  value = upper(var.datapump_target_schema)
}

output "service_name" {
  value = local.service_name
}

output "runtime_files" {
  value = concat(
    [{
      source_path = local_sensitive_file.wallet.filename
      target_name = "adb-wallet.zip"
      mode        = "0600"
      extract_to  = "adb-wallet"
      # JupyterLab runs as UID 1000 inside rootless Podman.
      container_uid       = "1000"
      container_name      = "oci-image-pilot-jupyter"
      container_read_path = "/home/adb-wallet/tnsnames.ora"
    }],
    var.datapump_enabled ? [{
      source_path         = local_sensitive_file.datapump[0].filename
      target_name         = "lanl-datapump.json"
      mode                = "0600"
      extract_to          = ""
      container_uid       = ""
      container_name      = ""
      container_read_path = ""
    }] : []
  )
  sensitive = true
}
