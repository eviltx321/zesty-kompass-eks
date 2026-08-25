variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "eu-west-1" # Ireland
}

variable "aws_profile" {
  description = "AWS CLI/SDK profile used for all AWS API calls. Must have administrator access in the target account."
  type        = string
  default     = "695214758399_AdministratorAccess"
}

variable "cluster_name" {
  description = "Name of the EKS cluster. Matches global.cxLogging.clusterName in the original values.yaml."
  type        = string
  default     = "zesty-kompass"
}

variable "kubernetes_version" {
  description = "Kubernetes version for the EKS control plane. Pinned explicitly (rather than left null) - leaving it null makes an internal eks-module data source's count depend on an unknown value at plan time. 1.35 is one version behind the current latest (1.36) for safer addon-version availability."
  type        = string
  default     = "1.35"
}

# --- Existing VPC (my-eks-vpc-stack-VPC) ---
# Purpose-built EKS VPC already present in account 695214758399 / eu-west-1, provisioned via
# CloudFormation stack "my-eks-vpc-stack" (template: "Amazon EKS Sample VPC - Private and Public
# subnets"). Already shared by 4 other demo EKS clusters in this account. No new subnets, NAT
# gateways, or route tables are created by this configuration - we only reference what exists.

variable "vpc_id" {
  description = "Existing VPC to deploy the cluster into."
  type        = string
  default     = "vpc-03f7d8969ed41919f" # my-eks-vpc-stack-VPC
}

variable "private_subnet_ids" {
  description = "Existing private subnet IDs (worker nodes go here). One per AZ: eu-west-1a, eu-west-1b."
  type        = list(string)
  default = [
    "subnet-0ff8727ad83f7ac9c", # my-eks-vpc-stack-PrivateSubnet01, eu-west-1a, 192.168.128.0/18
    "subnet-0f8f7e5f801f278e3", # my-eks-vpc-stack-PrivateSubnet02, eu-west-1b, 192.168.192.0/18
  ]
}

variable "public_subnet_ids" {
  description = "Existing public subnet IDs (control-plane ENIs / load balancers). One per AZ: eu-west-1a, eu-west-1b."
  type        = list(string)
  default = [
    "subnet-0fc865394b2e77086", # my-eks-vpc-stack-PublicSubnet01, eu-west-1a, 192.168.0.0/18
    "subnet-000282829ce039d48", # my-eks-vpc-stack-PublicSubnet02, eu-west-1b, 192.168.64.0/18
  ]
}

# --- Node group sizing ---

variable "node_instance_type" {
  description = "EC2 instance type for the managed node group. t3.large (not t3.medium) because kompass-victoria-metrics-0 alone requests 3Gi memory - t3.medium's ~3.3Gi allocatable doesn't leave enough room for it plus everything else already scheduled."
  type        = string
  default     = "t3.large"
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "node_min_size" {
  type    = number
  default = 1
}

variable "node_max_size" {
  type    = number
  default = 3
}

# --- Zesty Kompass install ---
# The AWS account is already registered with Zesty, so we install Kompass directly from the
# existing values.yaml rather than provisioning a new account registration (see zesty.tf).

variable "kompass_values_file" {
  description = "Path to the Kompass Helm values.yaml for the already-registered Zesty account."
  type        = string
  default     = "/home/edrio/values.yaml"
}

variable "tags" {
  description = "Additional tags applied to all created resources."
  type        = map(string)
  default     = {}
}
