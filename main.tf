provider "aws" {
  region = var.region
}

# Filter out local zones, which are not currently supported 
# with managed node groups
data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  cluster_name = "devlink-eks"

}

# resource "random_string" "suffix" {
#   length  = 8
#   special = false
# }

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.0.0"

  name = "main-vpc"

  cidr = "10.194.0.0/16"
  azs  = ["ap-northeast-2a", "ap-northeast-2c"]
# subnet을 10.0.0.0/24 로 하니 로드밸런서에서 이슈가 발생하여 194로 교체진행해봄.
  private_subnets = ["10.194.0.0/24", "10.194.1.0/24"]
  public_subnets  = ["10.194.100.0/24", "10.194.101.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  public_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "owned" 
    "kubernetes.io/role/elb"                      = 1
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "owned"
    "kubernetes.io/role/internal-elb"             = 1
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "19.15.3"

  cluster_name    = local.cluster_name
  cluster_version = "1.28"

  vpc_id                         = module.vpc.vpc_id
  subnet_ids                     = module.vpc.private_subnets
  cluster_endpoint_public_access = true

  eks_managed_node_group_defaults = {
    ami_type = "AL2_x86_64"

  }
 cluster_addons = {
     coredns = {
     most_recent = true
     }
     kube-proxy = {
     most_recent = true
     }
     vpc-cni = {
     most_recent = true
     }
 }
  eks_managed_node_groups = {
    one = {
      name = "node-group-1"

      instance_types = ["t3.small"]
      capacity_type  = "SPOT"

      min_size     = 1
      max_size     = 10
      desired_size = 2
    }


# 당장은 쓰지 않을 것
    # two = {
    #   name = "node-group-2"

    #   instance_types = ["t3.small"]

    #   min_size     = 1
    #   max_size     = 2
    #   desired_size = 1
    # }
  }
}


# https://aws.amazon.com/blogs/containers/amazon-ebs-csi-driver-is-now-generally-available-in-amazon-eks-add-ons/ 
data "aws_iam_policy" "ebs_csi_policy" {
  arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

module "irsa-ebs-csi" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role-with-oidc"
  version = "4.7.0"

  create_role                   = true
  role_name                     = "AmazonEKSTFEBSCSIRole-${module.eks.cluster_name}"
  provider_url                  = module.eks.oidc_provider
  role_policy_arns              = [data.aws_iam_policy.ebs_csi_policy.arn]
  oidc_fully_qualified_subjects = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
}

resource "aws_eks_addon" "ebs-csi" {
  cluster_name                  = module.eks.cluster_name
  addon_name                    = "aws-ebs-csi-driver"
  addon_version                 = "v1.20.0-eksbuild.1"
  service_account_role_arn      = module.irsa-ebs-csi.iam_role_arn
  resolve_conflicts_on_update   = "PRESERVE"

  tags = {
    "eks_addon" = "ebs-csi"
    "terraform" = "true"
  }
}
