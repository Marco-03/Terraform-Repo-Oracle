output "workshop_resource_summary" {
  description = "Safe project-resource details printed after tests."
  value       = module.workshop_resources.summary
}

output "workshop_test_context" {
  description = "Sensitive project-resource values passed only to provisioning tests."
  value       = module.workshop_resources.test_context
  sensitive   = true
}
