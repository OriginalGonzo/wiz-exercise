# Wiz Support Technical Exercise

A deliberately misconfigured 3-tier AWS application demonstrating cloud/DevOps proficiency and security posture awareness.

## Overview

This project implements a task management application with intentional security misconfigurations for the Wiz Support Technical Exercise interview.

### Architecture

```
Internet → NLB → EKS (Web App + CronJob) → EC2 (MongoDB)
                              ↓
                        S3 Bucket (Public Backups)
```

### Tech Stack

| Layer | Technology |
|-------|------------|
| Cloud Provider | AWS |
| IaC | Terraform + terraform-aws-modules |
| K8s Package Manager | Helm 3 |
| CI/CD | GitHub Actions |
| Container Registry | GHCR |
| Web App | Node.js/Express |
| Database | MongoDB 4.4 on EC2 |
| K8s Cluster | Amazon EKS |

## Repository Structure

```
.
├── .github/workflows/
│   ├── infra.yml           # Terraform CI
│   └── app.yml             # Docker build + Helm deploy CI
├── app/
│   ├── package.json
│   ├── server.js
│   ├── Dockerfile
│   └── wizexercise.txt
├── helm/wizapp/
│   ├── Chart.yaml
│   ├── values.yaml
│   ├── values-prod.yaml
│   └── templates/
│       ├── _helpers.tpl
│       ├── namespace.yaml
│       ├── deployment.yaml
│       ├── service.yaml
│       ├── serviceaccount.yaml
│       ├── rbac.yaml
│       ├── configmap.yaml
│       ├── secret.yaml
│       └── cronjob.yaml
├── infra/environments/dev/
│   ├── backend.tf
│   ├── main.tf
│   ├── variables.tf
│   ├── terraform.tfvars
│   ├── outputs.tf
│   └── user_data.sh
├── docs/
│   ├── troubleshooting.md
│   └── presentation.md
├── README.md
└── PLAN.md
```

## Intentional Misconfigurations

| # | Misconfiguration | Location |
|---|-------------------|----------|
| 1 | Outdated OS (Ubuntu 18.04) | EC2 AMI |
| 2 | Outdated MongoDB 4.4 | EC2 user_data.sh |
| 3 | SSH open to internet | Security Group |
| 4 | Overly permissive IAM (AdministratorAccess) | EC2 Instance Profile |
| 5 | Public S3 bucket | S3 Bucket Policy |
| 6 | Container as cluster-admin | Helm rbac.yaml |
| 7 | Container runs as root | Helm deployment.yaml |

## Prerequisites

- AWS account with appropriate permissions
- GitHub repository with secrets configured
- Terraform >= 1.7.0
- kubectl >= 1.29
- Helm >= 3.14

## Setup

### 1. Manual Bootstrap

Create S3 bucket and DynamoDB table for Terraform state:

```bash
aws s3api create-bucket --bucket wiz-exercise-tfstate-<unique-id> --region us-east-1
aws dynamodb create-table \
  --table-name wiz-exercise-tflock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST
```

### 2. GitHub Secrets

Configure these secrets in your repository:
- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `AWS_REGION`
- `GHCR_PAT`
- `TF_STATE_BUCKET`
- `TF_LOCK_TABLE`

### 3. Deploy Infrastructure

Push to `main` branch or trigger `infra.yml` workflow manually with `apply` action.

### 4. Update Helm Values

After infrastructure is deployed, update `helm/wizapp/values.yaml` with:
- `db.uri` - MongoDB connection string with EC2 private IP
- `backup.bucket` - Actual S3 bucket name

### 5. Deploy Application

Push changes to `app/` or `helm/` directories, or trigger `app.yml` workflow.

## Cleanup

After the interview, run the `infra.yml` workflow with `destroy` action to tear down all resources.

## Cost

Estimated monthly cost if left running: ~$200-250/month

**Important:** Destroy resources after use.

## License

MIT