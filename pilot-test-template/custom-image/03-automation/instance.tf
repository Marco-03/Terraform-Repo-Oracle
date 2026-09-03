data "oci_identity_availability_domain" "ad" {
  compartment_id = var.ociTenancyOcid
  ad_number      = 1
}

data "oci_core_subnet" "public" {
  subnet_id = var.ociPublicSubnetOcid
}

module "image_metadata" {
  source = "../02-edit-if-needed/metadata"

  app_user                         = var.app_user
  web_title                        = var.web_title
  db_password_override             = var.db_password_override
  additional_metadata              = var.additional_metadata
  generated_password_metadata_keys = var.generated_password_metadata_keys
}

module "adb" {
  source = "../02-edit-if-needed/adb"

  context = {
    compartment_ocid     = var.ociCompartmentOcid
    region               = var.ociRegionIdentifier
    resource_id          = local.res_id
    resource_name_prefix = var.resource_name_prefix
  }

  admin_password = module.image_metadata.db_password
  compute_count  = var.adb_compute_count
  storage_tbs    = var.adb_storage_tbs
  db_version     = var.adb_db_version
}

resource "oci_core_network_security_group" "workshop_access" {
  count = var.enable_test_access_nsg ? 1 : 0

  compartment_id = var.ociCompartmentOcid
  display_name   = "${var.resource_name_prefix}-${local.res_id}-access"
  vcn_id         = data.oci_core_subnet.public.vcn_id

  freeform_tags = {
    "purpose" = "temporary-image-test-access"
  }

  lifecycle {
    precondition {
      condition     = var.tester_source_cidr != ""
      error_message = "tester_source_cidr is required when enable_test_access_nsg is true."
    }
  }
}

resource "oci_core_network_security_group_security_rule" "workshop_tcp_ingress" {
  for_each = var.enable_test_access_nsg ? {
    for port in var.allowed_tcp_ports : tostring(port) => port
  } : {}

  network_security_group_id = oci_core_network_security_group.workshop_access[0].id
  direction                 = "INGRESS"
  protocol                  = "6"
  source                    = var.tester_source_cidr
  source_type               = "CIDR_BLOCK"
  stateless                 = false
  description               = "Temporary image test access on TCP ${each.value}"

  tcp_options {
    destination_port_range {
      min = each.value
      max = each.value
    }
  }
}

resource "oci_core_instance" "workshop" {
  count               = var.instance_count
  availability_domain = data.oci_identity_availability_domain.ad.name
  compartment_id      = var.ociCompartmentOcid
  display_name        = "${var.resource_name_prefix}-${local.res_id}-${format("%02d", count.index + 1)}"
  shape               = local.instance_shape

  metadata = merge(
    module.image_metadata.instance_metadata,
    module.adb.instance_metadata,
    {
      ssh_authorized_keys = var.resUserPublicKey
      compartment_ocid    = var.ociCompartmentOcid
    }
  )

  dynamic "shape_config" {
    for_each = local.is_flex_shape
    content {
      ocpus         = var.instance_shape_config_ocpus
      memory_in_gbs = var.instance_shape_config_memory_in_gbs
    }
  }

  create_vnic_details {
    assign_public_ip = true
    display_name     = "${var.resource_name_prefix}-${local.res_id}-${format("%02d", count.index + 1)}-${local.timestamp}"
    hostname_label   = "mtest${format("%02d", count.index + 1)}"
    nsg_ids          = var.enable_test_access_nsg ? [oci_core_network_security_group.workshop_access[0].id] : []
    subnet_id        = var.ociPublicSubnetOcid
  }

  source_details {
    source_id               = var.instance_image_id
    source_type             = "image"
    boot_volume_size_in_gbs = 250
  }

  depends_on = [oci_core_app_catalog_subscription.mp_image_subscription]

  lifecycle {
    ignore_changes = [
      display_name,
      create_vnic_details[0].display_name,
      create_vnic_details[0].hostname_label,
    ]
  }
}
