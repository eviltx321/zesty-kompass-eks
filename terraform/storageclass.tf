# values.yaml (global.storageClassName, and per-component storageClassName under
# kompass-insights.persistence, victoriaMetrics, victoriaMetricsCluster, grafana) all expect a
# StorageClass literally named "gp2". EKS auto-creates its own default "gp2" StorageClass on
# cluster bootstrap, backed by the deprecated in-tree provisioner (kubernetes.io/aws-ebs) - not
# functional for actually provisioning volumes on this Kubernetes version. Deleting it is a
# prerequisite for kubernetes_storage_class.gp2 below (same name, so it 409s otherwise); this hit
# every deploy attempt so far and always needed a manual `kubectl delete storageclass gp2`, so
# it's automated here via local-exec rather than left as a manual step.

resource "null_resource" "delete_default_gp2_storageclass" {
  triggers = {
    cluster_name = module.eks.cluster_name
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      KUBECONFIG_FILE=$(mktemp)
      aws eks update-kubeconfig \
        --name ${module.eks.cluster_name} \
        --region ${var.aws_region} \
        --profile ${var.aws_profile} \
        --kubeconfig "$KUBECONFIG_FILE"
      kubectl --kubeconfig="$KUBECONFIG_FILE" delete storageclass gp2 --ignore-not-found=true
      rm -f "$KUBECONFIG_FILE"
    EOT
  }

  depends_on = [
    aws_eks_pod_identity_association.ebs_csi,
  ]
}

# A freshly created EKS cluster access entry (from enable_cluster_creator_admin_permissions) can
# take a short while to propagate to the API server's authorization layer. The null_resource
# above authenticates via a separately-invoked `kubectl` (ambient CLI credential resolution) and
# isn't affected, but the kubernetes/helm *providers'* own bearer token (data.aws_eks_cluster_auth
# in providers.tf) hit this window directly once: a completely fresh cluster's first
# kubernetes_storage_class.gp2 apply failed with a bare "Error: Unauthorized" that a plain retry
# a few minutes later resolved with no config changes. This sleep absorbs that propagation delay
# instead of relying on a manual retry.
resource "time_sleep" "wait_for_access_entry_propagation" {
  create_duration = "30s"

  depends_on = [
    aws_eks_pod_identity_association.ebs_csi,
  ]
}

# Deletes the EKS default first (see resource above), so this create doesn't 409.
resource "kubernetes_storage_class" "gp2" {
  metadata {
    name = "gp2"
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    type = "gp2"
  }

  # Same reasoning as aws_eks_pod_identity_association.ebs_csi in eks.tf: depending on the whole
  # module here would again wait on the aws-ebs-csi-driver addon it's meant to sit alongside, not
  # block behind it. The kubernetes provider config already implicitly requires the cluster to
  # exist.
  depends_on = [
    aws_eks_pod_identity_association.ebs_csi,
    null_resource.delete_default_gp2_storageclass,
    time_sleep.wait_for_access_entry_propagation,
  ]
}
