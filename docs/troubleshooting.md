# Troubleshooting Guide

Document any issues encountered during the Wiz Support Technical Exercise and their resolutions.

---

## Infrastructure Issues

### Issue 1: Terraform init fails — backend bucket not found

**Problem:** `terraform init` fails with `NoSuchBucket`.

**Diagnosis:**
```powershell
aws s3api head-bucket --bucket wiz-exercise-tfstate-12345
```

**Resolution:** Run the bootstrap commands from `docs/cli-operations.md` Phase 1 first:
```powershell
aws s3api create-bucket --bucket wiz-exercise-tfstate-12345 --region us-east-1
aws dynamodb create-table --table-name wiz-exercise-tflock --attribute-definitions AttributeName=LockID,AttributeType=S --key-schema AttributeName=LockID,KeyType=HASH --billing-mode PAY_PER_REQUEST
```

---

### Issue 2: Terraform init fails — DynamoDB table not found

**Problem:** `terraform init` fails with `ResourceNotFoundException`.

**Resolution:** Create the DynamoDB table:
```powershell
aws dynamodb create-table `
  --table-name wiz-exercise-tflock `
  --attribute-definitions AttributeName=LockID,AttributeType=S `
  --key-schema AttributeName=LockID,KeyType=HASH `
  --billing-mode PAY_PER_REQUEST
```

---

### Issue 3: Plan fails — Ubuntu 18.04 AMI not found

**Problem:** `terraform plan` fails because the Ubuntu 18.04 AMI is deprecated in the region.

**Diagnosis:**
```powershell
aws ec2 describe-images --owners 099720109477 --filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-bionic-18.04-amd64-server-*"
```

**Resolution:** Update `main.tf` to use a more recent Ubuntu LTS or Amazon Linux 2:
```hcl
data "aws_ami" "ubuntu_2204" {
  most_recent = true
  owners      = ["099720109477"]
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}
```
Then update the module reference to `data.aws_ami.ubuntu_2204.id`.

---

## Network & Security Group Issues

### Issue 4: Security Group Rules Blocking DB Traffic

**Problem:** EKS pods couldn't connect to MongoDB on EC2 — connection timeout.

**Diagnosis:**
```powershell
kubectl logs <pod-name> -n wizapp
# Error: mongoose.connect failed - ETIMEDOUT
```

**Resolution:** Verify `sg-db-vm` allows port 27017 from VPC CIDR (10.0.0.0/16):
```powershell
aws ec2 describe-security-groups --group-ids <sg-id> --query 'SecurityGroups[0].IpPermissions'
```

Check that EKS nodes are in the same VPC and that the `db_vm` is in a public subnet with a routable path to EKS nodes.

---

### Issue 5: SSH to MongoDB EC2 fails

**Problem:** Cannot SSH to the EC2 instance from the internet.

**Diagnosis:**
```powershell
aws ec2 describe-security-groups --group-ids <sg-id> --query 'SecurityGroups[0].IpPermissions'
```

**Resolution:** This is an **intentional misconfiguration** (SSH open to 0.0.0.0/0). For the exercise, verify the SG rule exists:
```
Port 22 | 0.0.0.0/0 | SSH from internet (intentionally insecure)
```

If SSH still fails, check:
1. EC2 has a public IP — `terraform output db_vm_public_ip`
2. Internet Gateway is attached to the VPC
3. Route table has `0.0.0.0/0` → Internet Gateway

---

### Issue 6: EKS nodes can't access S3 for backups (no VPC endpoint)

**Problem:** CronJob pods fail when uploading to S3 — timeout or access denied.

**Diagnosis:**
```powershell
kubectl logs <cronjob-pod> -n wizapp
# Error: upload failed: could not locate credentials
```

**Resolution:** The backup bucket is public-read so no IAM credentials needed. However, if NAT Gateway traffic is an issue, create an S3 VPC Gateway Endpoint:
```powershell
aws ec2 create-vpc-endpoint `
  --vpc-id <vpc-id> `
  --service-name s3 `
  --route-table-ids <private-route-table-id>
```

---

## Kubernetes / Helm Issues

### Issue 7: Helm Chart Template Errors

**Problem:** `helm upgrade --install` fails with template rendering errors.

**Diagnosis:**
```powershell
helm template ./helm/wizapp --debug 2>&1 | Select-String "error"
```

**Resolution:** Common fixes:
- Ensure all `include` calls reference defined templates in `_helpers.tpl`
- Verify `Values` keys exist in `values.yaml` (e.g., `.Values.backup.irsaRoleArn`)
- Check for missing quotes in string values

---

### Issue 8: IRSA Role Not Mapping Correctly

**Problem:** CronJob pods can't write to S3 despite IRSA role existing in AWS.

**Diagnosis:**
```powershell
# Check if pod has the role annotated
kubectl get pod <backup-pod-name> -n wizapp -o yaml | Select-String "aws.amazonaws.com"

# Check the service account annotation
kubectl get sa wizapp-mongodb-backup -n wizapp -o yaml
```

**Resolution:** Ensure the backup ServiceAccount has the IRSA annotation:
```powershell
# Get the IRSA role ARN from Terraform output
terraform output backup_irsa_role_arn

# The backup-serviceaccount.yaml already includes this via values:
# backup:
#   irsaRoleArn: "<role-arn>"
```

Set the value in `helm/wizapp/values.yaml`:
```yaml
backup:
  irsaRoleArn: "arn:aws:iam::123456789:role/wiz-exercise-backup-role"
```

---

### Issue 9: ImagePullBackOff — GHCR credentials not configured

**Problem:** Pods fail to pull the Docker image from GHCR.

**Diagnosis:**
```powershell
kubectl get pods -n wizapp
# ImagePullBackOff: Unauthorized
```

**Resolution:** Create the GHCR pull secret in the wizapp namespace:
```powershell
kubectl create secret docker-registry ghcr-secret `
  --docker-server=ghcr.io `
  --docker-username=<github-username> `
  --docker-password=<ghcr-pat> `
  --namespace=wizapp
```

The `app.yml` GitHub Actions workflow handles this automatically. For local testing, run the above.

---

### Issue 10: ClusterRoleBinding not created — Helm template error

**Problem:** `rbac.yaml` fails to apply.

**Diagnosis:**
```powershell
helm template ./helm/wizapp --namespace wizapp | Select-String "ClusterRoleBinding"
```

**Resolution:** Verify the template uses correct API version and syntax:
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
# ...
roleRef:
  kind: ClusterRole
  name: cluster-admin
```

Check for typos in `apiGroup` field (should be `rbac.authorization.k8s.io`).

---

## Database Issues

### Issue 11: MongoDB Authentication Failure

**Problem:** App can't authenticate to MongoDB — `AuthenticationFailed`.

**Diagnosis:**
```powershell
# SSH to EC2 and connect locally
mongosh admin -u admin -p --eval "db.getUsers()"
```

**Resolution:** Verify the connection string includes `authSource=admin`:
```
mongodb://admin:changeme@<private-ip>:27017/wizapp?authSource=admin
```

Check user exists:
```javascript
db.getUser("admin")
```

If user is missing, the `user_data.sh` script may have failed. Re-run the setup section manually on the EC2 instance.

---

### Issue 12: MongoDB bindIp misconfiguration

**Problem:** MongoDB only accepts connections from localhost.

**Diagnosis:**
```powershell
mongosh --host <private-ip> --port 27017
# Error: Connection refused
```

**Resolution:** SSH to EC2 and check `/etc/mongod.conf`:
```bash
grep -A2 "bindIp" /etc/mongod.conf
# Should show: bindIp: 0.0.0.0
```

If `bindIp: 127.0.0.1`, the `user_data.sh` sed command may have failed. Fix:
```bash
sudo sed -i 's/bindIp: 127.0.0.1/bindIp: 0.0.0.0/' /etc/mongod.conf
sudo systemctl restart mongod
```

---

## Docker / Container Issues

### Issue 13: Docker build fails — layer caching issue

**Problem:** Docker build fails or is very slow.

**Resolution:**
```powershell
docker build --no-cache -t ghcr.io/your-username/wiz-exercise-app:latest ./app
```

Use `--no-cache` if dependencies are stale.

---

### Issue 14: Docker push fails — not authenticated to GHCR

**Problem:** `docker push` fails with `unauthorized`.

**Resolution:** Re-login to GHCR:
```powershell
echo $env:GHCR_PAT | docker login ghcr.io -u your-github-username --password-stdin
```

---

## General Debugging Commands

```powershell
# Check EKS cluster connectivity
kubectl cluster-info

# List all resources in namespace
kubectl get all -n wizapp

# Follow pod logs in real time
kubectl logs -f <pod-name> -n wizapp

# Describe a resource for events and conditions
kubectl describe <resource> <name> -n wizapp

# List Helm releases
helm list -n wizapp

# Check CronJob and job history
kubectl get cronjob -n wizapp
kubectl get jobs -n wizapp

# Check pod resource usage
kubectl top pods -n wizapp

# Port-forward to test locally
kubectl port-forward svc/wizapp-wizapp 3000:80 -n wizapp
```

---

## Quick Diagnosis Checklist

| Check | Command |
|-------|---------|
| Terraform state accessible | `aws s3 ls s3://wiz-exercise-tfstate-12345/` |
| DynamoDB lock table exists | `aws dynamodb describe-table --table-name wiz-exercise-tflock` |
| EKS cluster is responsive | `aws eks describe-cluster --name wiz-exercise-cluster` |
| EC2 instance is running | `aws ec2 describe-instances --filters "Name=tag:Name,Values=MongoDB-VM"` |
| Security group rules | `aws ec2 describe-security-groups --group-ids <sg-id>` |
| S3 bucket is public | `aws s3api get-bucket-policy --bucket <bucket-name>` |
| Helm chart renders | `helm template wizapp ./helm/wizapp --namespace wizapp` |
| Pods running | `kubectl get pods -n wizapp -o wide` |