output "cluster_endpoint" {
  description = "EKS cluster endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "db_vm_private_ip" {
  description = "MongoDB VM private IP"
  value       = module.db_vm.private_ip
}

output "db_vm_public_ip" {
  description = "MongoDB VM public IP"
  value       = module.db_vm.public_ip
}

output "backup_bucket_name" {
  description = "S3 backup bucket name"
  value       = module.backup_bucket.s3_bucket_id
}

output "backup_bucket_url" {
  description = "S3 backup bucket domain name"
  value       = module.backup_bucket.s3_bucket_bucket_domain_name
}