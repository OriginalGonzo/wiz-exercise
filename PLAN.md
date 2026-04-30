# Wiz Support Technical Exercise

> **Goal:** Build a deliberately misconfigured 3-tier application on AWS to demonstrate both cloud/DevOps proficiency and security posture awareness for the Wiz Support Engineering interview.

---

## 1. Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              INTERNET                                         │
└────────────┬────────────────────────────────────────────────────────────────┘
             │
             ├─► SSH (22) ───────────────────────┐
             │                                    ▼
             │                         ┌─────────────────────┐
             │                         │   EC2 (Public Subnet) │
             │                         │  Outdated Linux +     │
             │                         │  Outdated MongoDB     │
             │                         │  Overly Permissive IAM│
             │                         └──────────┬────────────┘
             │                                    │ 27017
             │                                    │
             │                         ┌──────────▼────────────┐
             │                         │   Security Group      │
             │                         │   MongoDB: EKS only   │
             │                         └──────────┬────────────┘
             │                                    │
             ├─► HTTP/HTTPS (80/443) ─────────────┼─────────────────────┐
             │                                    │                     │
             │                                    ▼                     ▼
             │                         ┌──────────────────────────────────────┐
             │                         │        EKS Cluster (Private Subnets)   │
             │                         │  ┌─────────────────────────────────┐   │
             │                         │  │  Web App Pod                    │   │
             │                         │  │  - Runs as cluster-admin        │   │
             │                         │  │  - Contains wizexercise.txt     │   │
             │                         │  │  - DB auth via connection string│   │
             │                         │  └─────────────────────────────────┘   │
             │                         │  ┌─────────────────────────────────┐   │
             │                         │  │  CronJob (mongodump → S3)       │   │
             │                         │  │  - Runs every hour              │   │
             │                         │  └─────────────────────────────────┘   │
             │                         └──────────────────────────────────────┘
             │                                    │
             │                                    │ Service (Type: LoadBalancer)
             │                                    │
             │                         ┌──────────▼────────────┐
             │                         │   AWS NLB             │
             │                         │   (Public Subnet)     │
             │                         └───────────────────────┘
             │
             ├─► S3 Public Read / List ◄── K8s CronJob DB Backups
             │
             ▼
    ┌─────────────────┐
    │   S3 Bucket     │
    │  Public Backups │
    └─────────────────┘
```

### Key Tech Stack
| Layer | Technology |
|-------|------------|
| **Cloud Provider** | AWS |
| **IaC** | Terraform + terraform-aws-modules |
| **K8s Package Manager** | Helm 3 |
| **CI/CD** | GitHub Actions |
| **Container Registry** | GHCR (GitHub Container Registry) |
| **Web App** | Minimal Node.js/Express app |
| **Database** | MongoDB on EC2 (outdated versions) |
| **Backups** | Kubernetes CronJob → mongodump → S3 |
| **K8s Cluster** | Amazon EKS (via terraform-aws-modules) |

---

## 2. Network Layout

### VPC Design (10.0.0.0/16)

We use the [`terraform-aws-modules/vpc/aws`](https://github.com/terraform-aws-modules/terraform-aws-vpc) module.

| Subnet Type | CIDR Block | AZs | Purpose |
|-------------|------------|-----|---------|
| **Public** | 10.0.1.0/24, 10.0.2.0/24 | 2 | NLB, NAT Gateways, MongoDB EC2 |
| **Private** | 10.0.3.0/24, 10.0.4.0/24 | 2 | EKS worker nodes (backup CronJob runs here) |

### Routing
- **Public Subnets**: Route `0.0.0.0/0` → Internet Gateway
- **Private Subnets**: Route `0.0.0.0/0` → NAT Gateway (in public subnet)
- **S3 VPC Gateway Endpoint**: Keeps backup traffic off NAT to avoid charges and improve performance

### Security Groups

1. **`sg-eks-nodes`** (managed by EKS module)
   - Ingress: All traffic from within VPC (10.0.0.0/16)
   - Ingress: App port from NLB security group
   - Egress: All

2. **`sg-db-vm`** (intentionally weak SSH)
   - Ingress: **22 (SSH) from `0.0.0.0/0`** ← Misconfiguration #1
   - Ingress: **27017 (MongoDB) from `sg-eks-nodes` only** ← Correctly scoped
   - Egress: All

3. **`sg-nlb`**
   - Ingress: 80, 443 from `0.0.0.0/0`
   - Egress: To `sg-eks-nodes` on app port

> **Presentation note:** Call out SSH-from-internet risk. Discuss Wiz findings and remediation (SSM Session Manager, bastion host).

---

## 3. Terraform Infrastructure

### Backend Bootstrap (Manual Step)

Before any Terraform runs, manually create:
- **S3 bucket** for Terraform state (e.g., `wiz-exercise-tfstate-<unique-id>`)
- **DynamoDB table** for state locking (e.g., `wiz-exercise-tflock`, primary key `LockID`)

```bash
aws s3api create-bucket --bucket wiz-exercise-tfstate-12345 --region us-east-1
aws dynamodb create-table \
  --table-name wiz-exercise-tflock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST
```

### File Structure
```
infra/
├── environments/
│   ├── dev/
│   │   ├── backend.tf           # S3 backend config
│   │   ├── main.tf              # Module calls + overrides
│   │   ├── variables.tf
│   │   ├── terraform.tfvars     # env-specific values
│   │   └── outputs.tf
│   └── prod/                    # (Optional, same structure)
├── modules/
│   └── github_oidc/             # (Optional) GitHub Actions OIDC for AWS auth
├── global_vars.tf               # Shared variables (if using terragrunt or symlinks)
└── README.md
```

### Module Usage

We leverage the official `terraform-aws-modules` to avoid boilerplate:

| Resource | Module |
|----------|--------|
| **VPC** | `terraform-aws-modules/vpc/aws` |
| **EKS** | `terraform-aws-modules/eks/aws` |
| **Security Groups** | `terraform-aws-modules/security-group/aws` |
| **S3 Bucket** | `terraform-aws-modules/s3-bucket/aws` |
| **EC2 Instance** | `terraform-aws-modules/ec2-instance/aws` |
| **IAM** | `terraform-aws-modules/iam/aws` (for policies/roles) |

### 3.1 VPC Module (`environments/dev/main.tf`)

```hcl
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "wiz-exercise-vpc"
  cidr = "10.0.0.0/16"

  azs             = ["us-east-1a", "us-east-1b"]
  public_subnets  = ["10.0.1.0/24", "10.0.2.0/24"]
  private_subnets = ["10.0.3.0/24", "10.0.4.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true   # Cost saving for dev
  enable_dns_hostnames = true
  enable_dns_support   = true

  public_subnet_tags  = { "kubernetes.io/role/elb" = "1" }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = "1" }
}
```

### 3.2 EKS Module

```hcl
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = "wiz-exercise-cluster"
  cluster_version = "1.29"  # Use a supported version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_endpoint_public_access = true

  eks_managed_node_groups = {
    default = {
      desired_size = 2
      min_size     = 1
      max_size     = 3
      instance_types = ["t3.medium"]
    }
  }

  enable_oidc_provider = true  # Enables IRSA for future use
}
```

### 3.3 MongoDB EC2 VM Module (`ec2-instance` module)

```hcl
module "db_vm" {
  source  = "terraform-aws-modules/ec2-instance/aws"
  version = "~> 5.0"

  name = "wiz-exercise-mongodb"

  # Outdated AMI: Ubuntu 18.04 LTS (EOL, known CVEs)
  ami                    = data.aws_ami.ubuntu_1804.id
  instance_type          = "t3.small"
  subnet_id              = module.vpc.public_subnets[0]
  vpc_security_group_ids = [module.db_sg.security_group_id]
  iam_instance_profile   = module.db_vm_role.iam_instance_profile_name

  user_data = templatefile("${path.module}/user_data.sh", {
    db_password = var.mongodb_password
  })

  tags = { Name = "MongoDB-VM" }
}
```

**User Data Script** (`user_data.sh`):
```bash
#!/bin/bash
set -e

# Install outdated MongoDB 4.4 (EOL, has CVEs)
wget -qO - https://www.mongodb.org/static/pgp/server-4.4.asc | sudo apt-key add -
echo "deb [ arch=amd64,arm64 ] https://repo.mongodb.org/apt/ubuntu bionic/mongodb-org/4.4 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-4.4.list
sudo apt-get update
sudo apt-get install -y mongodb-org=4.4.29 mongodb-org-server=4.4.29 mongodb-org-shell=4.4.29 mongodb-org-mongos=4.4.29 mongodb-org-tools=4.4.29

# Pin versions so auto-updates don't happen (intentionally outdated)
echo "mongodb-org hold" | sudo dpkg --set-selections
echo "mongodb-org-server hold" | sudo dpkg --set-selections
echo "mongodb-org-shell hold" | sudo dpkg --set-selections
echo "mongodb-org-mongos hold" | sudo dpkg --set-selections
echo "mongodb-org-tools hold" | sudo dpkg --set-selections

# Configure MongoDB with authentication
sudo mkdir -p /data/db
sudo sed -i 's/bindIp: 127.0.0.1/bindIp: 0.0.0.0/' /etc/mongod.conf
sudo tee -a /etc/mongod.conf <<EOF
security:
  authorization: enabled
EOF

sudo systemctl start mongod
sudo systemctl enable mongod

# Wait for MongoDB to start
sleep 5

# Create admin user
mongosh admin --eval "
  db.createUser({
    user: 'admin',
    pwd: '${db_password}',
    roles: [ { role: 'userAdminAnyDatabase', db: 'admin' }, 'readWriteAnyDatabase' ]
  });
"

# Install AWS CLI v2
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip -q awscliv2.zip
sudo ./aws/install
```

> **Note:** No backup cron here anymore — backups are handled by the K8s CronJob.

### 3.4 S3 Backup Bucket (via Terraform)

```hcl
module "backup_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "~> 4.0"

  bucket = "wiz-exercise-backups-${random_id.suffix.hex}"

  acl = "public-read"  # Intentionally insecure for exercise

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
      Resource  = [
        "arn:aws:s3:::wiz-exercise-backups-${random_id.suffix.hex}",
        "arn:aws:s3:::wiz-exercise-backups-${random_id.suffix.hex}/*"
      ]
    }]
  })
}
```

> **Presentation note:** Explain that `public-read`, disabled block public access, and Principal `*` are all severe data-exposure risks. Wiz would flag this as Critical.

### 3.5 IAM — Overly Permissive DB VM Role

```hcl
module "db_vm_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role"
  version = "~> 5.0"

  create_role = true
  role_name   = "wiz-exercise-db-vm-role"
  trusted_role_services = ["ec2.amazonaws.com"]
  create_instance_profile = true

  custom_role_policy_arns = ["arn:aws:iam::aws:policy/AdministratorAccess"]
}
```

> **Presentation note:** AdministratorAccess on a VM is a massive risk. Any compromise of the app or SSH gives full AWS account control.

### 3.6 Security Group Module for DB

```hcl
module "db_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.0"

  name        = "wiz-exercise-db-sg"
  description = "Security group for MongoDB VM"
  vpc_id      = module.vpc.vpc_id

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
      cidr_blocks = module.vpc.vpc_cidr_block
    }
  ]

  egress_rules = ["all-all"]
}
```

---

## 4. Application (Minimal Node/Express)

### Directory: `app/`

```
app/
├── package.json
├── server.js
├── Dockerfile
└── wizexercise.txt          # Also baked into image via Dockerfile
```

### `server.js` (Minimal Task App)
```javascript
const express = require('express');
const mongoose = require('mongoose');
const app = express();
app.use(express.json());

const MONGODB_URI = process.env.MONGODB_URI || 'mongodb://localhost:27017/wizapp';
mongoose.connect(MONGODB_URI);

const TaskSchema = new mongoose.Schema({ title: String, done: Boolean });
const Task = mongoose.model('Task', TaskSchema);

app.get('/', async (req, res) => {
  const tasks = await Task.find();
  res.json({ tasks, message: 'Wiz Exercise App' });
});

app.post('/tasks', async (req, res) => {
  const task = new Task(req.body);
  await task.save();
  res.json(task);
});

app.get('/health', (req, res) => res.json({ status: 'ok' }));

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => console.log(`Server running on port ${PORT}`));
```

### `Dockerfile`
```dockerfile
FROM node:18-alpine
WORKDIR /app
COPY package*.json ./
RUN npm ci --only=production
COPY . .
# Required by exercise:
RUN echo "Wiz Support Technical Exercise v3.0" > /app/wizexercise.txt
EXPOSE 3000
USER node
CMD ["node", "server.js"]
```

> **Note:** We run as `node` user in the Dockerfile, but then override at the Pod level via Helm to run as root/cluster-admin to satisfy the intentional misconfiguration. This shows deeper understanding.

### `package.json`
```json
{
  "name": "wiz-exercise-app",
  "version": "1.0.0",
  "dependencies": {
    "express": "^4.18.2",
    "mongoose": "^8.0.0"
  },
  "scripts": {
    "start": "node server.js"
  }
}
```

---

## 5. Helm Chart for Kubernetes

### Directory Structure
```
helm/
├── wizapp/
│   ├── Chart.yaml
│   ├── values.yaml
│   ├── values-prod.yaml        # Overrides for prod/dev
│   └── templates/
│       ├── _helpers.tpl
│       ├── namespace.yaml
│       ├── deployment.yaml
│       ├── service.yaml
│       ├── serviceaccount.yaml
│       ├── rbac.yaml           # cluster-admin binding (intentionally bad)
│       ├── configmap.yaml
│       ├── secret.yaml
│       └── cronjob.yaml        # mongodump backup job
```

### Key Templates

#### `service.yaml` — Public Access via NLB
```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ include "wizapp.fullname" . }}
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: "nlb"
    service.beta.kubernetes.io/aws-load-balancer-scheme: "internet-facing"
spec:
  type: LoadBalancer
  ports:
    - port: 80
      targetPort: 3000
      protocol: TCP
  selector:
    app.kubernetes.io/name: {{ include "wizapp.name" . }}
```

#### `rbac.yaml` — Intentional Misconfiguration
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: {{ include "wizapp.fullname" . }}-admin
subjects:
  - kind: ServiceAccount
    name: {{ include "wizapp.serviceAccountName" . }}
    namespace: {{ .Release.Namespace }}
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
```

#### `serviceaccount.yaml` — With Image Pull Secret
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "wizapp.serviceAccountName" . }}
imagePullSecrets:
  - name: ghcr-secret
```

#### `deployment.yaml` — Running as Root (intentionally bad)
```yaml
apiVersion: apps/v1
kind: Deployment
spec:
  template:
    spec:
      serviceAccountName: {{ include "wizapp.serviceAccountName" . }}
      securityContext:
        runAsUser: 0    # root (intentionally bad — Dockerfile sets node:node)
        runAsGroup: 0
      containers:
        - name: {{ .Chart.Name }}
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          env:
            - name: MONGODB_URI
              valueFrom:
                secretKeyRef:
                  name: {{ include "wizapp.fullname" . }}-db
                  key: uri
          ports:
            - containerPort: 3000
          livenessProbe:
            httpGet:
              path: /health
              port: 3000
          readinessProbe:
            httpGet:
              path: /health
              port: 3000
```

#### `cronjob.yaml` — Hourly DB Backup to S3
```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: {{ include "wizapp.fullname" . }}-mongodb-backup
spec:
  schedule: "0 * * * *"   # Every hour
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: OnFailure
          containers:
            - name: mongodump
              image: mongo:4.4   # Match the outdated DB version
              command:
                - /bin/sh
                - -c
                - |
                  DATE=$(date +%Y%m%d_%H%M%S)
                  mongodump --uri="$MONGODB_URI" --out=/tmp/dump_$DATE
                  tar -czf /tmp/backup_$DATE.tar.gz -C /tmp dump_$DATE
                  aws s3 cp /tmp/backup_$DATE.tar.gz s3://{{ .Values.backup.bucket }}/
                  rm -rf /tmp/dump_$DATE /tmp/backup_$DATE.tar.gz
              env:
                - name: MONGODB_URI
                  valueFrom:
                    secretKeyRef:
                      name: {{ include "wizapp.fullname" . }}-db
                      key: uri
                - name: AWS_DEFAULT_REGION
                  value: {{ .Values.backup.awsRegion }}
          serviceAccountName: {{ include "wizapp.fullname" . }}-mongodb-backup
```

> **Backup auth recommendation:** Use **IRSA (IAM Roles for Service Accounts)** with the EKS OIDC provider. This is the AWS-native way and looks professional. Create an IAM role with S3 write permissions and annotate the backup ServiceAccount.

### Helm Values (`values.yaml`)
```yaml
image:
  repository: ghcr.io/<owner>/wiz-exercise-app
  tag: latest
  pullPolicy: IfNotPresent

replicaCount: 2

service:
  type: LoadBalancer
  port: 80

db:
  uri: "mongodb://admin:changeme@<db-private-ip>:27017/wizapp?authSource=admin"

backup:
  enabled: true
  bucket: "wiz-exercise-backups-<suffix>"
  awsRegion: "us-east-1"
  schedule: "0 * * * *"
```

---

## 6. GitHub Actions CI/CD Pipelines

### Repository Secrets Required

| Secret | Description |
|--------|-------------|
| `AWS_ACCESS_KEY_ID` | IAM user for Terraform CI |
| `AWS_SECRET_ACCESS_KEY` | IAM user secret |
| `AWS_REGION` | e.g., `us-east-1` |
| `GHCR_PAT` | GitHub PAT with `read:packages`, `write:packages` |
| `TF_STATE_BUCKET` | S3 bucket for Terraform state |
| `TF_LOCK_TABLE` | DynamoDB table for state locking |

### 6.1 Infrastructure Pipeline (`.github/workflows/infra.yml`)

```yaml
name: Deploy Infrastructure

on:
  push:
    branches: [main]
    paths: ['infra/**']
  workflow_dispatch:
    inputs:
      action:
        description: 'Terraform action'
        required: true
        default: 'apply'
        type: choice
        options:
          - plan
          - apply
          - destroy

jobs:
  terraform:
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: infra/environments/dev
    steps:
      - uses: actions/checkout@v4

      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: "1.7.0"

      - name: Configure AWS Credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: ${{ secrets.AWS_REGION }}

      - name: Terraform Init
        run: terraform init -backend-config="bucket=${{ secrets.TF_STATE_BUCKET }}" -backend-config="dynamodb_table=${{ secrets.TF_LOCK_TABLE }}"

      - name: Terraform Plan
        if: github.event.inputs.action != 'destroy'
        run: terraform plan -out=tfplan

      - name: Terraform Apply
        if: github.event.inputs.action == 'apply'
        run: terraform apply -auto-approve tfplan

      - name: Terraform Destroy
        if: github.event.inputs.action == 'destroy'
        run: terraform destroy -auto-approve
```

### 6.2 Application Pipeline (`.github/workflows/app.yml`)

```yaml
name: Build & Deploy App

on:
  push:
    branches: [main]
    paths: ['app/**', 'helm/**']
  workflow_dispatch:

env:
  REGISTRY: ghcr.io
  IMAGE_NAME: ${{ github.repository }}/wiz-exercise-app

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    outputs:
      image_tag: ${{ steps.meta.outputs.tags }}
      image_sha: ${{ github.sha }}
    steps:
      - uses: actions/checkout@v4

      - uses: docker/setup-buildx-action@v3

      - name: Login to GHCR
        uses: docker/login-action@v3
        with:
          registry: ${{ env.REGISTRY }}
          username: ${{ github.actor }}
          password: ${{ secrets.GHCR_PAT }}

      - name: Extract metadata
        id: meta
        uses: docker/metadata-action@v5
        with:
          images: ${{ env.REGISTRY }}/${{ env.IMAGE_NAME }}
          tags: |
            type=sha,prefix=,suffix=,format=short
            type=raw,value=latest

      - name: Build & Push
        uses: docker/build-push-action@v5
        with:
          context: ./app
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          labels: ${{ steps.meta.outputs.labels }}

  deploy:
    needs: build
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS Credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: ${{ secrets.AWS_REGION }}

      - name: Update kubeconfig
        run: aws eks update-kubeconfig --name wiz-exercise-cluster --region ${{ secrets.AWS_REGION }}

      - name: Install Helm
        uses: azure/setup-helm@v4
        with:
          version: '3.14.0'

      - name: Create GHCR Pull Secret
        run: |
          kubectl create namespace wizapp --dry-run=client -o yaml | kubectl apply -f -
          kubectl create secret docker-registry ghcr-secret \
            --docker-server=ghcr.io \
            --docker-username=${{ github.actor }} \
            --docker-password=${{ secrets.GHCR_PAT }} \
            --namespace=wizapp \
            --dry-run=client -o yaml | kubectl apply -f -

      - name: Deploy Helm Chart
        run: |
          helm upgrade --install wizapp ./helm/wizapp \
            --namespace wizapp \
            --set image.tag=${{ github.sha }} \
            --set image.repository=${{ env.REGISTRY }}/${{ env.IMAGE_NAME }} \
            --wait --timeout 5m
```

---

## 7. Kubernetes CronJob for Backups

As detailed in the Helm chart, the backup runs as a **CronJob in EKS** rather than on the EC2 VM. Benefits:
- Demonstrates Kubernetes-native patterns
- Easier to monitor (`kubectl get cronjobs`, `kubectl logs job/...`)
- Keeps the EC2 user_data simpler
- Can leverage IRSA for secure S3 access without hardcoding credentials

### IRSA Setup (Recommended for Backup Auth)

In Terraform, after the EKS module creates the OIDC provider:

```hcl
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
```

Then annotate the CronJob's ServiceAccount in Helm:
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "wizapp.fullname" . }}-mongodb-backup
  annotations:
    eks.amazonaws.com/role-arn: {{ .Values.backup.irsaRoleArn }}
```

> **Presentation note:** IRSA is the modern, secure way. Contrast it with putting AWS keys in a K8s Secret or giving the EKS node instance profile S3 access (which would let any pod write to S3).

---

## 8. Intentional Misconfigurations Summary

| # | Misconfiguration | Location | Wiz Finding |
|---|-------------------|----------|-------------|
| 1 | **Outdated OS** (Ubuntu 18.04) | EC2 AMI | VM Vulnerability |
| 2 | **Outdated MongoDB 4.4** | EC2 `user_data.sh` | VM Vulnerability |
| 3 | **SSH open to internet** | Security Group rule | Network Exposure |
| 4 | **Overly permissive IAM** (`AdministratorAccess`) | EC2 Instance Profile | IAM Risk |
| 5 | **Public S3 bucket** | Bucket policy | Data Exposure |
| 6 | **Container as cluster-admin** | Helm `rbac.yaml` | K8s RBAC Risk |
| 7 | **Container runs as root** | Helm `deployment.yaml` securityContext | Container Security |

> **Pro tip for the interview:** After showing each, say: "Wiz would flag this as a Critical/WARNING finding. The remediation would be..."

---

## 9. Repository Structure

```
wiz-exercise/
├── .github/
│   └── workflows/
│       ├── infra.yml           # Terraform CI (with destroy option)
│       └── app.yml             # Docker build + Helm deploy CI
├── app/
│   ├── package.json
│   ├── server.js
│   ├── Dockerfile
│   └── wizexercise.txt
├── helm/
│   └── wizapp/
│       ├── Chart.yaml
│       ├── values.yaml
│       ├── values-prod.yaml
│       └── templates/
│           ├── _helpers.tpl
│           ├── namespace.yaml
│           ├── deployment.yaml
│           ├── service.yaml
│           ├── serviceaccount.yaml
│           ├── rbac.yaml
│           ├── configmap.yaml
│           ├── secret.yaml
│           └── cronjob.yaml
├── infra/
│   ├── environments/
│   │   └── dev/
│   │       ├── backend.tf      # S3 backend
│   │       ├── main.tf         # Module calls
│   │       ├── variables.tf
│   │       ├── terraform.tfvars
│   │       ├── outputs.tf
│   │       └── user_data.sh
│   └── modules/
│       └── (optional github_oidc)
├── README.md
├── PLAN.md
└── docs/
    ├── troubleshooting.md      # Your debugging log!
    └── presentation.md         # Interview slide outline
```

---

## 10. Execution Order

1. **Manual Bootstrap**
   - Create AWS account / ensure IAM user exists
   - Create S3 bucket + DynamoDB table for Terraform state
   - Generate GitHub PAT for GHCR
   - Add all secrets to GitHub repository

2. **Run Infra Pipeline**
   - Triggers on push to `infra/` or manually via `workflow_dispatch`
   - Creates: VPC → EKS → EC2 (MongoDB) → S3 (backups) → IAM → SGs

3. **Verify DB**
   - SSH to EC2 (using the open-to-internet SG and keypair)
   - Confirm MongoDB is running and auth is enabled
   - Note the private IP for the connection string

4. **Update Helm Values**
   - Set `db.uri` with actual EC2 private IP and password
   - Set `backup.bucket` with actual bucket name
   - Commit to repo (or pass via `--set` in CI)

5. **Create GHCR Pull Secret in EKS**
   - Done automatically by the `app.yml` pipeline

6. **Run App Pipeline**
   - Builds Docker image → pushes to GHCR
   - Deploys Helm chart to EKS with `helm upgrade --install`

7. **Verify**
   - `kubectl get svc -n wizapp` → get NLB DNS
   - `curl http://<nlb-dns>/health`
   - Open app in browser, create a task
   - Wait for CronJob (or manually trigger: `kubectl create job --from=cronjob/wizapp-mongodb-backup test-backup -n wizapp`)
   - Verify backup exists in S3 and is publicly accessible via URL

8. **Post-Interview**
   - Trigger `workflow_dispatch` with `destroy` to clean up everything

---

## 11. Presentation Outline

1. **Architecture Diagram** — Walk through the 3 tiers
2. **IaC Demo** — Show Terraform modules, `terraform plan` output, state in S3
3. **CI/CD Demo** — Walk through GitHub Actions: infra pipeline + app pipeline
4. **Live App** — Show the web app, create a task
5. **Backup Demo** — Show the K8s CronJob, the S3 bucket, and open a backup URL in browser
6. **Security Findings** — Walk through the 7 intentional misconfigurations, explain what Wiz would flag, and how you'd remediate
7. **Troubleshooting Log** — Share `docs/troubleshooting.md`. Discuss any issues (e.g., Security Group rules blocking DB traffic, Helm chart errors, IRSA role not mapping correctly)
8. **Q&A**

---

## 12. Open Questions / Decisions

| Question | Recommendation |
|----------|----------------|
| **AWS Region?** | `us-east-1` — cheapest, most AMI availability |
| **Ubuntu 18.04 AMI?** | Use `data.aws_ami` filter in Terraform; note that some regions may have deprecated it. Have a fallback to Amazon Linux 2 with an old release date. |
| **MongoDB 4.4 available?** | Yes via MongoDB's own repo. Pin version to prevent accidental updates. |
| **IRSA for backups?** | Yes — shows modern AWS K8s knowledge. Add the IRSA module to Terraform. |
| **Helm release name?** | `wizapp` in namespace `wizapp` |
| **Terraform workspace or env folder?** | Env folder (`infra/environments/dev/`) is cleaner for interviews. Can easily add `prod/` to show maturity. |
| **Cost estimate?** | ~$200-250/month if left running. **Destroy after interview.** |

---

## 13. Cost Estimation (if left running)

| Resource | Spec | ~Monthly |
|----------|------|----------|
| EKS Control Plane | — | $72 |
| EKS Nodes | 2x t3.medium | $60 |
| EC2 MongoDB | t3.small | $15 |
| NAT Gateway | 1x | $32 |
| NLB | LCU + hours | ~$20 |
| S3 | < 1GB | ~$0.02 |
| **Total** | | **~$200** |

> **Critical:** Add a `destroy` option to the infra pipeline and run it after the interview.
