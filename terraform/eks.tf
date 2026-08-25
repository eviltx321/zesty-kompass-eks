locals {
  tags = merge(var.tags, {
    ManagedBy = "terraform"
    Project   = "zesty-kompass"
  })
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  vpc_id                   = data.aws_vpc.selected.id
  subnet_ids               = var.private_subnet_ids
  control_plane_subnet_ids = concat(var.private_subnet_ids, var.public_subnet_ids)

  endpoint_public_access  = true
  endpoint_private_access = true

  # Grants the applying IAM principal (695214758399_AdministratorAccess) a cluster admin
  # access entry automatically, so kubectl works right after apply without extra aws-auth wiring.
  enable_cluster_creator_admin_permissions = true

  addons = {
    # before_compute = true installs these before the module waits on node-group health. vpc-cni
    # in particular is the CNI plugin nodes need to report Ready at all - left at the module's
    # default (after compute), the module waits on nodes that can never become Ready without it,
    # and the node group times out and fails after ~20min with zero addons ever created.
    vpc-cni                = { before_compute = true }
    kube-proxy             = { before_compute = true }
    eks-pod-identity-agent = { before_compute = true } # required for the Kompass insights-agent and EBS CSI pod identity associations below
    coredns                = {}
    aws-ebs-csi-driver     = {} # provides the ebs.csi.aws.com provisioner backing the "gp2" StorageClass values.yaml expects
  }

  eks_managed_node_groups = {
    default = {
      instance_types = [var.node_instance_type]
      min_size       = var.node_min_size
      max_size       = var.node_max_size
      desired_size   = var.node_desired_size
      subnet_ids     = var.private_subnet_ids
    }
  }

  tags = local.tags
}

# --- EBS CSI driver permissions via Pod Identity ---
# The aws-ebs-csi-driver addon needs IAM permissions to create/attach EBS volumes. We use EKS Pod
# Identity (rather than IRSA) since the cluster already runs the eks-pod-identity-agent addon for
# Kompass's insights-agent role below - keeps auth model consistent across both add-ons.

data "aws_iam_policy_document" "eks_pod_identity_assume" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name               = "${var.cluster_name}-ebs-csi-driver"
  assume_role_policy = data.aws_iam_policy_document.eks_pod_identity_assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_pod_identity_association" "ebs_csi" {
  # Deliberately no `depends_on = [module.eks]` here: that would force this to wait for the
  # *entire* module - including the aws-ebs-csi-driver addon itself, which needs this association
  # to get its own IAM permissions. The `cluster_name` reference below is enough to order this
  # after the cluster exists without waiting on unrelated addons (this bit us once already: the
  # addon sat in CrashLoopBackOff / CREATING for a 20min timeout with the old depends_on).
  cluster_name    = module.eks.cluster_name
  namespace       = "kube-system"
  service_account = "ebs-csi-controller-sa"
  role_arn        = aws_iam_role.ebs_csi.arn
}
