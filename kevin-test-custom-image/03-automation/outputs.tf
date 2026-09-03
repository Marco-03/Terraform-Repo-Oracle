output "workshop_desc" {
  value = [format(
    "OCI image pilot launch. Count: %s instance(s). Shape: %s.",
    var.instance_count,
    local.instance_shape
  )]
}

output "instances" {
  value = formatlist(
    "%s - %s",
    oci_core_instance.workshop.*.display_name,
    oci_core_instance.workshop.*.public_ip
  )
}

output "test_instance_public_ips" {
  description = "Public IP addresses used by the isolated custom-image test runner."
  value       = oci_core_instance.workshop.*.public_ip
}

output "web_url" {
  value = formatlist(
    "http://%s:32180",
    oci_core_instance.workshop.*.public_ip
  )
}

output "dashboard_url" {
  value = formatlist(
    "http://%s:32180",
    oci_core_instance.workshop.*.public_ip
  )
}

output "dashboard_user" {
  value = ["opc"]
}

output "dashboard_password" {
  value = var.expose_login_outputs ? [nonsensitive(module.image_metadata.vnc_password)] : []
}

output "jupyter_url" {
  value = formatlist(
    "http://%s:8888/lab",
    oci_core_instance.workshop.*.public_ip
  )
}

output "test_nsg_ocid" {
  value = var.enable_test_access_nsg ? oci_core_network_security_group.workshop_access[0].id : null
}

output "ssh_command" {
  value = formatlist(
    "ssh opc@%s",
    oci_core_instance.workshop.*.public_ip
  )
}

output "app_user" {
  value = [module.adb.workshop_user]
}

# LiveLabs/WMS-compatible names retained alongside the local test outputs.
output "database_user" {
  value = [module.adb.workshop_user]
}

output "app_user_password" {
  value     = [module.image_metadata.db_password]
  sensitive = true
}

output "database_password" {
  value = var.expose_login_outputs ? [nonsensitive(module.image_metadata.db_password)] : []
}

output "database_admin_password" {
  value     = [module.image_metadata.db_password]
  sensitive = true
}

output "vnc_password" {
  value     = [module.image_metadata.vnc_password]
  sensitive = true
}

output "jupyter_lab" {
  value = [formatlist(
    "http://%s:8888/lab",
    oci_core_instance.workshop.*.public_ip
  )]
}

output "jupyter_notebook_password" {
  value = var.expose_login_outputs ? [nonsensitive(module.image_metadata.vnc_password)] : []
}

output "jupyter_password" {
  description = "Sensitive scalar Jupyter password for local image testing."
  value       = module.image_metadata.vnc_password
  sensitive   = true
}

output "generated_metadata_passwords" {
  description = "Additional generated metadata passwords requested by the image author."
  value       = module.image_metadata.generated_passwords
  sensitive   = true
}

output "adb_service" {
  value = [module.adb.service_name]
}

output "runtime_files" {
  description = "Protected ADB wallet staged onto the test VM after SSH is available."
  value       = module.adb.runtime_files
  sensitive   = true
}
