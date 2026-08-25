# The AWS account (695214758399) is already registered with Zesty - values.yaml's
# assumeRole.roleArn / zestyExternalID / orgID / API keys are for that existing registration
# (its clusterName, "zesty-kompass", already matches this cluster). So there's no account to
# create here: we just install the Kompass Helm chart into the new cluster, joining it to that
# existing account, using values.yaml as-is.
#
# (Earlier this file used terraform-aws-zesty-account's `zesty_account` module to *create* a new
# account registration - that's what a fresh onboarding needs, but it 400'd here precisely
# because the account already exists. That module + its CUR/Glue/Athena/IAM resources have been
# dropped in favor of this simpler path.)

resource "helm_release" "kompass" {
  name       = "kompass"
  repository = "https://zesty-co.github.io/kompass"
  chart      = "kompass"
  # Pinned to match the version referenced in zesty-ecr-access-report.md (the prior onboarding
  # attempt this values.yaml came from). Installing latest (0.3.10) against this values.yaml left
  # several components erroring ("couldn't find key ORG_ID in Secret kompass-insights-secret",
  # PVCs with no storageClassName applied) - looks like the values schema shifted since 0.3.7.
  version          = "0.3.7"
  namespace        = "zesty-system"
  create_namespace = true
  cleanup_on_fail  = true
  wait             = false # the chart creates some resources via Helm hooks after the main release
  timeout          = 300

  values = [file(var.kompass_values_file)]

  # module.eks here (unlike the pod identity association / storage class above) is NOT circular -
  # nothing addon-related depends back on this helm_release, so waiting on the whole module is
  # safe. It's also necessary: the chart's own kompass-validation pre-install hook checks that
  # the EBS CSI driver is actually running, not just that the gp2 StorageClass object exists.
  # aws-ebs-csi-driver isn't a before_compute addon (correctly - it doesn't gate node readiness
  # the way vpc-cni does), so without this it can still be mid-creation when Helm installs,
  # and kompass-validation fails with "AWS EBS CSI Driver is not installed".
  depends_on = [
    module.eks,
    kubernetes_storage_class.gp2,
  ]
}
