data "aws_ami" "ubuntu_2204" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

data "aws_vpc" "existing" {
  count = var.use_existing_vpc ? 1 : 0
  tags  = { Name = var.existing_vpc_name }
}

data "aws_subnets" "public" {
  count = var.use_existing_vpc ? 1 : 0
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.existing.0.id]
  }
  tags = { Name = "*public*" }
}

data "aws_subnets" "private" {
  count = var.use_existing_vpc ? 1 : 0
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.existing.0.id]
  }
  tags = { Name = "*private*" }
}

locals {
  vpc_id          = var.use_existing_vpc ? data.aws_vpc.existing[0].id : module.vpc[0].vpc_id
  public_subnets  = var.use_existing_vpc ? data.aws_subnets.public[0].ids : module.vpc[0].public_subnets
  private_subnets = var.use_existing_vpc ? data.aws_subnets.private[0].ids : module.vpc[0].private_subnets
}

module "vpc" {
  count   = var.use_existing_vpc ? 0 : 1
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "wiz-exercise-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["us-east-1a", "us-east-1b"]
  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnets = ["10.0.3.0/24", "10.0.4.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags  = { "kubernetes.io/role/elb" = "1" }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = "1" }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = "wiz-exercise-cluster"
  cluster_version = "1.30"

  vpc_id     = local.vpc_id
  subnet_ids = local.private_subnets

  cluster_endpoint_public_access = true

  eks_managed_node_groups = {
    default = {
      desired_size   = 2
      min_size       = 1
      max_size       = 3
      instance_types = ["t3.medium"]
    }
  }

}

module "db_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.0"

  name        = "wiz-exercise-db-sg"
  description = "Security group for MongoDB VM"
  vpc_id      = local.vpc_id

  ingress_with_cidr_blocks = [
    {
      from_port   = 22
      to_port     = 22
      protocol    = "tcp"
      description = "SSH from internet (intentionally insecure)"
      cidr_blocks = "0.0.0.0/0"
    },
    {
      from_port   = 27017
      to_port     = 27017
      protocol    = "tcp"
      description = "MongoDB from EKS nodes only"
      cidr_blocks = "10.0.0.0/16"
    }
  ]

  egress_rules = ["all-all"]
}

module "db_vm_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role"
  version = "~> 5.0"

  create_role             = true
  role_name               = "wiz-exercise-db-vm-role"
  trusted_role_services   = ["ec2.amazonaws.com"]
  create_instance_profile = true

  custom_role_policy_arns = ["arn:aws:iam::aws:policy/AdministratorAccess"]
}

module "db_vm" {
  source  = "terraform-aws-modules/ec2-instance/aws"
  version = "~> 5.0"

  name = "wiz-exercise-mongodb"

  ami                    = data.aws_ami.ubuntu_2204.id
  instance_type          = "t3.small"
  subnet_id              = local.public_subnets[0]
  vpc_security_group_ids = [module.db_sg.security_group_id]
  iam_instance_profile   = module.db_vm_role.iam_instance_profile_name

  user_data = templatefile("${path.module}/user_data.sh", {
    db_password = var.mongodb_password
  })

  tags = { Name = "MongoDB-VM" }
}

resource "random_id" "suffix" {
  byte_length = 8
}

module "backup_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 4.0"

  bucket = "wiz-exercise-backups-${random_id.suffix.hex}"

  acl = "public-read"

  control_object_ownership = true
  object_ownership         = "BucketOwnerPreferred"

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false

  attach_policy = true
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "PublicReadGetObject"
      Effect    = "Allow"
      Principal = "*"
      Action    = ["s3:GetObject", "s3:ListBucket"]
      Resource = [
        "arn:aws:s3:::wiz-exercise-backups-${random_id.suffix.hex}",
        "arn:aws:s3:::wiz-exercise-backups-${random_id.suffix.hex}/*"
      ]
    }]
  })
}

module "backup_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.0"

  role_name = "wiz-exercise-backup-role"

  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["wizapp:wizapp-mongodb-backup"]
    }
  }

  role_policy_arns = {
    s3 = aws_iam_policy.backup_s3.arn
  }
}

resource "aws_iam_policy" "backup_s3" {
  name = "wiz-exercise-backup-s3"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["s3:PutObject", "s3:ListBucket"]
      Resource = [
        module.backup_bucket.s3_bucket_arn,
        "${module.backup_bucket.s3_bucket_arn}/*"
      ]
    }]
  })
}