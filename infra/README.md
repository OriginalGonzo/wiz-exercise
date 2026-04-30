# Infrastructure

This directory contains Terraform configurations for the Wiz Support Technical Exercise.

## Structure

```
infra/
├── environments/
│   └── dev/
│       ├── backend.tf      # S3 backend configuration
│       ├── main.tf         # Module calls (VPC, EKS, EC2, S3, IAM)
│       ├── variables.tf    # Input variables
│       ├── terraform.tfvars # Environment-specific values
│       ├── outputs.tf      # Useful outputs
│       └── user_data.sh    # EC2 bootstrap script
└── modules/
    └── github_oidc/        # (Optional) GitHub Actions OIDC for AWS auth
```

## Modules Used

| Resource | Module | Version |
|----------|--------|---------|
| VPC | `terraform-aws-modules/vpc/aws` | ~> 5.0 |
| EKS | `terraform-aws-modules/eks/aws` | ~> 20.0 |
| Security Group | `terraform-aws-modules/security-group/aws` | ~> 5.0 |
| S3 Bucket | `terraform-aws-modules/s3-bucket/aws` | ~> 4.0 |
| EC2 Instance | `terraform-aws-modules/ec2-instance/aws` | ~> 5.0 |
| IAM Role | `terraform-aws-modules/iam/aws` | ~> 5.0 |

## Bootstrap

Before first run, create the Terraform state backend manually:

```bash
aws s3api create-bucket --bucket wiz-exercise-tfstate-<unique-id> --region us-east-1
aws dynamodb create-table \
  --table-name wiz-exercise-tflock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST
```

## Usage

```bash
cd infra/environments/dev
terraform init -backend-config="bucket=<your-bucket>" -backend-config="dynamodb_table=<your-table>"
terraform plan
terraform apply
```

## Outputs

After apply, note:
- `db_vm_private_ip` — for MongoDB connection string
- `backup_bucket_name` — for Helm values
- `cluster_endpoint` — for kubectl configuration