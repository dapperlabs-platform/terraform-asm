/**
 * Copyright 2022 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

locals {
  // GKE release channel is a list with max length 1 https://github.com/hashicorp/terraform-provider-google/blob/9d5f69f9f0f74f1a8245f1a52dd6cffb572bbce4/google/resource_container_cluster.go#L954
  gke_release_channel          = data.google_container_cluster.asm.release_channel != null ? data.google_container_cluster.asm.release_channel[0].channel : ""
  gke_release_channel_filtered = lower(local.gke_release_channel) == "unspecified" ? "" : local.gke_release_channel
  // In order or precedence, use (1) user specified channel, (2) GKE release channel, and (3) regular channel
  channel       = lower(coalesce(var.channel, local.gke_release_channel_filtered, "regular"))
  revision_name = "asm-managed${local.channel == "regular" ? "" : "-${local.channel}"}"
  // Fleet ID should default to project ID if unset
  fleet_id = coalesce(var.fleet_id, var.project_id)
}

data "google_container_cluster" "asm" {
  project  = var.project_id
  name     = var.cluster_name
  location = var.cluster_location

  depends_on = [var.module_depends_on]
}

resource "kubernetes_namespace" "system" {
  count = var.create_system_namespace ? 1 : 0

  metadata {
    name = "istio-system"
  }
}

resource "kubernetes_config_map" "asm_options" {
  metadata {
    name      = "asm-options"
    namespace = try(kubernetes_namespace.system[0].metadata[0].name, "istio-system")
  }

  data = {
    multicluster_mode = var.multicluster_mode
    ASM_OPTS          = var.enable_cni ? "CNI=on" : null
  }

  depends_on = [google_gke_hub_membership.membership, google_gke_hub_feature.mesh, var.module_depends_on]
}

resource "kubernetes_manifest" "control_plane_revision" {
  count = var.create_cpr ? 1 : 0
  manifest = {
    "apiVersion" = "mesh.cloud.google.com/v1beta1"
    "kind"       = "ControlPlaneRevision"

    "metadata" = {
      "name"      = local.revision_name
      "namespace" = "istio-system"
      labels = {
        "mesh.cloud.google.com/managed-cni-enabled" = var.enable_cni
        "app.kubernetes.io/created-by"              = "terraform-module"
      }
      annotations = {
        "mesh.cloud.google.com/vpcsc" = var.enable_vpc_sc
      }
    }

    "spec" = {
      "type"    = "managed_service"
      "channel" = local.channel
    }
  }

  depends_on = [google_gke_hub_membership.membership, google_gke_hub_feature.mesh, var.module_depends_on]
}
