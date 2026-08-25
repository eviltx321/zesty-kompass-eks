# We do not create a VPC, subnets, or a NAT gateway here — the target account already has a
# purpose-built EKS VPC (see variables.tf for details). This data source exists purely to
# validate var.vpc_id resolves to a real, available VPC before the eks module tries to use it.

data "aws_vpc" "selected" {
  id = var.vpc_id
}
