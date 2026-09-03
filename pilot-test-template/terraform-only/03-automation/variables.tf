variable "ociTenancyOcid" {
  type    = string
  default = ""
}

variable "ociUserOcid" {
  type    = string
  default = ""
}

variable "ociCompartmentOcid" {
  type    = string
  default = ""
}

variable "ociRegionIdentifier" {
  type    = string
  default = ""
}

variable "ociAuthMethod" {
  type        = string
  description = "OCI provider authentication method. Local browser-session testing normally uses SecurityToken."
  default     = "APIKey"
}

variable "ociConfigProfile" {
  type        = string
  description = "Local OCI CLI profile used by Terraform."
  default     = "DEFAULT"
}

variable "resId" {
  type    = string
  default = ""
}

variable "resource_name_prefix" {
  type        = string
  description = "Portable display-name prefix for project resources."
  default     = "resource-test"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}$", var.resource_name_prefix))
    error_message = "resource_name_prefix must start with a lowercase letter and contain only lowercase letters, numbers, or hyphens."
  }
}

variable "ociVcnOcid" {
  type    = string
  default = ""
}

variable "ociPublicSubnetOcid" {
  type    = string
  default = ""
}

variable "ociPrivateSubnetOcid" {
  type    = string
  default = ""
}

variable "tester_source_cidr" {
  type        = string
  description = "Optional trusted CIDR for direct resource testing. Use the tester's current public IP with /32."
  default     = ""

  validation {
    condition = (
      var.tester_source_cidr == "" || (
        can(cidrhost(var.tester_source_cidr, 0)) &&
        !contains(["0.0.0.0/0", "::/0"], var.tester_source_cidr)
      )
    )
    error_message = "tester_source_cidr must be empty or restricted; public all-address CIDRs are not allowed."
  }
}

variable "generated_value_keys" {
  type        = set(string)
  description = "Names of passwords or values Terraform must generate for the project resource."
  default     = ["resource_password"]

  validation {
    condition = alltrue([
      for key in var.generated_value_keys :
      can(regex("^[a-z][a-z0-9_]{0,63}$", key))
    ])
    error_message = "generated_value_keys must contain lowercase identifiers."
  }
}

variable "generated_value_overrides" {
  type        = map(string)
  description = "Optional fixed values for repeatable tests. Leave empty to generate them."
  default     = {}
  sensitive   = true
}

variable "workshop_settings" {
  type        = map(string)
  description = "Non-secret project settings passed to the workshop resource module."
  default     = {}
}

variable "workshop_sensitive_settings" {
  type        = map(string)
  description = "Exceptional sensitive project settings. Prefer generated values when possible."
  default     = {}
  sensitive   = true
}
