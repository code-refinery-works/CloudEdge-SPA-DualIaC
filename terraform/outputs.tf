output "cloudfront_distribution_id" {
  description = "CloudFront Distribution ID (use for cache invalidation in CI/CD)"
  value       = aws_cloudfront_distribution.main.id
}

output "cloudfront_domain_name" {
  description = "CloudFront assigned domain name"
  value       = aws_cloudfront_distribution.main.domain_name
}

output "content_bucket_name" {
  description = "S3 bucket name for SPA artifacts deployment"
  value       = aws_s3_bucket.content.id
}

output "logs_bucket_name" {
  description = "S3 bucket name for access logs"
  value       = aws_s3_bucket.logs.id
}

output "waf_web_acl_arn" {
  description = "WAF WebACL ARN attached to CloudFront"
  value       = aws_wafv2_web_acl.main.arn
}

output "site_url" {
  description = "Public HTTPS URL of the SPA"
  value       = "https://${var.domain_name}"
}