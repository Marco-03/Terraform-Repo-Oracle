variable "ociTenancyOcid" {
  default = ""
}

variable "ociUserOcid" {
  default = ""
}

variable "ociCompartmentOcid" {
  default = ""
}

variable "ociUserPassword" {
  default = ""
}

variable "ociRegionIdentifier" {
  default = ""
}

variable "ociAuthMethod" {
  description = "OCI provider authentication method. Green Button uses APIKey; local browser-session testing uses SecurityToken."
  default     = "APIKey"
}

variable "ociConfigProfile" {
  description = "OCI CLI configuration profile used for local Terraform runs."
  default     = "DEFAULT"
}

variable "resId" {
  default = ""
}

variable "resource_name_prefix" {
  type        = string
  description = "Portable display-name prefix for resources created by this stack."
  default     = "oci-image-test"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}$", var.resource_name_prefix))
    error_message = "resource_name_prefix must start with a lowercase letter and contain only lowercase letters, numbers, or hyphens."
  }
}

variable "ociPrivateSubnetOcid" {
  default = ""
}

variable "ociPublicSubnetOcid" {
  default = ""
}

variable "ociVcnOcid" {
  default = ""
}

variable "resUserPublicKey" {
  default = ""
}

variable "use_marketplace_image" {
  description = "Use Marketplace listing subscription before launching the image. Keep false while testing a custom image OCID directly."
  type        = bool
  default     = false
}

variable "mp_listing_id" {
  description = "Marketplace listing OCID. Populate after the Marketplace listing exists."
  default     = ""
}

variable "mp_listing_resource_version" {
  description = "Marketplace listing resource version. Populate after the Marketplace artifact/version exists."
  default     = ""
}

variable "instance_image_id" {
  description = "Custom image OCID for local testing, or Marketplace image resource OCID after publication."
  default     = ""
}

variable "shape_use_flex" {
  default = true
}

variable "flex_instance_shape" {
  default = "VM.Standard.E4.Flex"
}

variable "fixed_instance_shape" {
  default = "VM.Standard.E4.Flex"
}

variable "instance_count" {
  default = 1
}

variable "enable_test_access_nsg" {
  type        = bool
  description = "Create a temporary NSG for direct image testing. Leave false for the normal Green Button network flow."
  default     = false
}

variable "expose_login_outputs" {
  type        = bool
  description = "Expose Green Button login outputs. The local automation sets this false so passwords are not printed."
  default     = true
}

variable "tester_source_cidr" {
  type        = string
  description = "Trusted CIDR allowed to reach the temporary test VM. Use the tester's current public IP with /32."
  default     = ""

  validation {
    condition = (
      var.tester_source_cidr == "" || (
        can(cidrhost(var.tester_source_cidr, 0)) &&
        !contains(["0.0.0.0/0", "::/0"], var.tester_source_cidr)
      )
    )
    error_message = "tester_source_cidr must be empty or a restricted CIDR such as 203.0.113.10/32; public all-address CIDRs are not allowed."
  }
}

variable "allowed_tcp_ports" {
  type        = list(number)
  description = "Fallback ports for a manual Terraform test. The automated runner derives SSH plus public endpoint ports from demo-code 01-edit/public-endpoints.json."
  default     = [22]

  validation {
    condition = (
      length(var.allowed_tcp_ports) > 0 &&
      length(distinct(var.allowed_tcp_ports)) == length(var.allowed_tcp_ports) &&
      alltrue([
        for port in var.allowed_tcp_ports :
        port >= 1 && port <= 65535 && floor(port) == port
      ])
    )
    error_message = "allowed_tcp_ports must contain unique whole-number ports from 1 through 65535."
  }
}

variable "instance_shape_config_ocpus" {
  default = 2
}

variable "instance_shape_config_memory_in_gbs" {
  default = 16
}

variable "web_title" {
  default = "OCI Image Pilot"
}

variable "app_user" {
  default = "GRAPHUSER"
}

variable "adb_compute_count" {
  description = "Autonomous Database ECPU count used for the temporary ADB test resource."
  type        = number
  default     = 2
}

variable "adb_storage_tbs" {
  description = "Autonomous Database storage in TB used for the temporary ADB test resource."
  type        = number
  default     = 1
}

variable "adb_db_version" {
  description = "Autonomous Database version for the pilot ADB test resource."
  type        = string
  default     = "26ai"
}

variable "datapump_enabled" {
  description = "Load the protected LANL dump into GRAPHUSER during Terraform provisioning."
  type        = bool
  default     = true
}

variable "datapump_dump_uris" {
  description = "Qualified Swift object paths for the four encrypted LANL Data Pump files."
  type        = list(string)
  default     = []
  sensitive   = true

  validation {
    condition = !var.datapump_enabled || (
      length(var.datapump_dump_uris) == 4 &&
      alltrue([for uri in var.datapump_dump_uris : can(regex("^/o/lanl/export_ogma_lanl_[0-9]{8}_0[1-4]\\.dmp$", uri))])
    )
    error_message = "datapump_dump_uris must contain the four /o/lanl/export_ogma_lanl_YYYYMMDD_01-04.dmp object paths when datapump_enabled is true."
  }
}

variable "datapump_encryption_password" {
  description = "Password used to decrypt the LANL Data Pump files. Keep it only in the ignored terraform.tfvars file."
  type        = string
  default     = ""
  sensitive   = true

  validation {
    condition     = !var.datapump_enabled || length(var.datapump_encryption_password) >= 8
    error_message = "datapump_encryption_password is required when datapump_enabled is true."
  }
}

variable "datapump_credential_name" {
  description = "Database credential name used by Data Pump for the Swift dump objects."
  type        = string
  default     = "LANL_SWIFT_CRED"

  validation {
    condition     = !var.datapump_enabled || can(regex("^[A-Za-z][A-Za-z0-9_]{0,29}$", var.datapump_credential_name))
    error_message = "datapump_credential_name must be a valid Oracle credential name."
  }
}

variable "datapump_credential_username" {
  description = "Swift credential username. Keep it only in the ignored terraform.tfvars file."
  type        = string
  default     = ""
  sensitive   = true

  validation {
    condition     = !var.datapump_enabled || length(var.datapump_credential_username) > 0
    error_message = "datapump_credential_username is required when datapump_enabled is true."
  }
}

variable "datapump_credential_password" {
  description = "Swift auth token/password. Keep it only in the ignored terraform.tfvars file."
  type        = string
  default     = ""
  sensitive   = true

  validation {
    condition     = !var.datapump_enabled || length(var.datapump_credential_password) > 0
    error_message = "datapump_credential_password is required when datapump_enabled is true."
  }
}

variable "datapump_source_schema" {
  type    = string
  default = "TESTUSER"
}

variable "datapump_target_schema" {
  type    = string
  default = "GRAPHUSER"

  validation {
    condition     = upper(var.datapump_target_schema) == "GRAPHUSER"
    error_message = "This workshop imports the dataset into GRAPHUSER."
  }
}

variable "linkurious_demo_enabled" {
  description = "Download and prepare Leo's Linkurious notebook demo from Object Storage during first boot."
  type        = bool
  default     = false
}

variable "linkurious_demo_par_url" {
  description = "Read-only Object Storage PAR base URL ending in /o/. Keep it only in the ignored terraform.tfvars file."
  type        = string
  default     = ""
  sensitive   = true

  validation {
    condition = !var.linkurious_demo_enabled || can(regex(
      "^https://objectstorage\\.[A-Za-z0-9-]+\\.oraclecloud\\.com/p/[A-Za-z0-9_-]+/n/[A-Za-z0-9_-]+/b/[A-Za-z0-9._-]+/o/$",
      var.linkurious_demo_par_url
    ))
    error_message = "linkurious_demo_par_url must be a read-only Object Storage PAR base URL ending in /o/ when linkurious_demo_enabled is true."
  }
}

variable "linkurious_demo_prefix" {
  description = "Object prefix below linkurious_demo_par_url that contains the mirrored Linkurious repository."
  type        = string
  default     = "LL/WMS_ID_12172/"

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9._/-]*/$", var.linkurious_demo_prefix)) && !strcontains(var.linkurious_demo_prefix, "..")
    error_message = "linkurious_demo_prefix must be a safe Object Storage prefix ending in /."
  }
}

variable "additional_metadata" {
  type        = map(string)
  description = "Optional static OCI metadata consumed by an application configuration hook."
  default     = {}
  sensitive   = true
}

variable "generated_password_metadata_keys" {
  type        = set(string)
  description = "Optional metadata keys that receive generated passwords for each VM."
  default     = []
}

variable "db_password_override" {
  description = "Optional fixed database/app password for repeatable tests. Leave empty to generate one."
  default     = ""
  sensitive   = true
}

locals {
  timestamp      = formatdate("YYYY-MM-DD-hhmmss", timestamp())
  res_id         = var.resId != "" ? var.resId : "test"
  instance_shape = var.shape_use_flex ? var.flex_instance_shape : var.fixed_instance_shape
  is_flex_shape  = var.shape_use_flex ? [var.instance_shape_config_ocpus] : []
}
