terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

locals {
  prefix = "${var.project}-${var.env}"
}

# ── S3: コンテンツバケット ──────────────────────────────────────────
resource "aws_s3_bucket" "content" {
  bucket        = "${local.prefix}-content-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}
resource "aws_s3_bucket_versioning" "content" {
  bucket = aws_s3_bucket.content.id
  versioning_configuration { status = "Enabled" }
}
resource "aws_s3_bucket_server_side_encryption_configuration" "content" {
  bucket = aws_s3_bucket.content.id
  rule { apply_server_side_encryption_by_default { sse_algorithm = "AES256" } }
}
resource "aws_s3_bucket_public_access_block" "content" {
  bucket                  = aws_s3_bucket.content.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

# ── S3: ログバケット ────────────────────────────────────────────────
resource "aws_s3_bucket" "logs" {
  bucket        = "${local.prefix}-logs-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
}
resource "aws_s3_bucket_ownership_controls" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule { object_ownership = "BucketOwnerPreferred" }
}
resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule { apply_server_side_encryption_by_default { sse_algorithm = "AES256" } }
}
resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule {
    id     = "archive"
    status = "Enabled"
    transition { days = 90; storage_class = "GLACIER" }
    filter {}
  }
}
resource "aws_s3_bucket_public_access_block" "logs" {
  bucket                  = aws_s3_bucket.logs.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

# ── ACM (us-east-1) ────────────────────────────────────────────────
resource "aws_acm_certificate" "cert" {
  provider          = aws.us_east_1
  domain_name       = var.domain_name
  validation_method = "DNS"
  subject_alternative_names = ["www.${var.domain_name}"]
  lifecycle { create_before_destroy = true }
}
data "aws_route53_zone" "zone" {
  name         = var.hosted_zone_name
  private_zone = false
}
resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.cert.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }
  zone_id = data.aws_route53_zone.zone.zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 60
}
resource "aws_acm_certificate_validation" "cert" {
  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.cert.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# ── WAF WebACL (us-east-1) ─────────────────────────────────────────
resource "aws_wafv2_web_acl" "main" {
  provider    = aws.us_east_1
  name        = "${local.prefix}-waf"
  scope       = "CLOUDFRONT"
  description = "SPA WAF"
  default_action { allow {} }
  rule {
    name     = "AWSManagedCommon"
    priority = 1
    override_action { none {} }
    statement {
      managed_rule_group_statement { vendor_name = "AWS"; name = "AWSManagedRulesCommonRuleSet" }
    }
    visibility_config { cloudwatch_metrics_enabled = true; metric_name = "common"; sampled_requests_enabled = true }
  }
  rule {
    name     = "RateLimit"
    priority = 2
    action { block {} }
    statement { rate_based_statement { limit = 2000; aggregate_key_type = "IP" } }
    visibility_config { cloudwatch_metrics_enabled = true; metric_name = "ratelimit"; sampled_requests_enabled = true }
  }
  visibility_config { cloudwatch_metrics_enabled = true; metric_name = "${local.prefix}-waf"; sampled_requests_enabled = true }
}

# ── CloudFront OAC & Function ──────────────────────────────────────
resource "aws_cloudfront_origin_access_control" "oac" {
  name                              = "${local.prefix}-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}
resource "aws_cloudfront_function" "spa" {
  name    = "${local.prefix}-spa-router"
  runtime = "cloudfront-js-2.0"
  publish = true
  code    = <<-EOF
    function handler(event) {
      var req = event.request;
      var uri = req.uri;
      if (uri.endsWith('/')) { req.uri = uri + 'index.html'; }
      else if (!uri.includes('.')) { req.uri = '/index.html'; }
      req.headers['x-content-type-options'] = [{key:'X-Content-Type-Options',value:'nosniff'}];
      req.headers['x-frame-options']        = [{key:'X-Frame-Options',value:'DENY'}];
      req.headers['referrer-policy']        = [{key:'Referrer-Policy',value:'strict-origin-when-cross-origin'}];
      return req;
    }
  EOF
}

# ── CloudFront Distribution ────────────────────────────────────────
resource "aws_cloudfront_distribution" "main" {
  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  aliases             = [var.domain_name, "www.${var.domain_name}"]
  web_acl_id          = aws_wafv2_web_acl.main.arn

  origin {
    domain_name              = aws_s3_bucket.content.bucket_regional_domain_name
    origin_id                = "s3-content"
    origin_access_control_id = aws_cloudfront_origin_access_control.oac.id
  }

  default_cache_behavior {
    target_origin_id       = "s3-content"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    cache_policy_id        = "658327ea-f89d-4fab-a63d-7e88639e58f6" # CachingOptimized
    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.spa.arn
    }
  }

  custom_error_response {
    error_code            = 403
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 0
  }
  custom_error_response {
    error_code            = 404
    response_code         = 200
    response_page_path    = "/index.html"
    error_caching_min_ttl = 0
  }

  logging_config {
    bucket          = aws_s3_bucket.logs.bucket_domain_name
    include_cookies = false
    prefix          = "cloudfront/"
  }

  restrictions { geo_restriction { restriction_type = "none" } }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.cert.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  depends_on = [aws_s3_bucket_public_access_block.content]
}

# ── S3 Bucket Policy (OAC) ─────────────────────────────────────────
data "aws_caller_identity" "current" {}
resource "aws_s3_bucket_policy" "content" {
  bucket = aws_s3_bucket.content.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudFrontOAC"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.content.arn}/*"
      Condition = { StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.main.arn } }
    }]
  })
}

# ── Route 53 Alias ─────────────────────────────────────────────────
resource "aws_route53_record" "apex" {
  zone_id = data.aws_route53_zone.zone.zone_id
  name    = var.domain_name
  type    = "A"
  alias {
    name                   = aws_cloudfront_distribution.main.domain_name
    zone_id                = aws_cloudfront_distribution.main.hosted_zone_id
    evaluate_target_health = false
  }
}
resource "aws_route53_record" "www" {
  zone_id = data.aws_route53_zone.zone.zone_id
  name    = "www.${var.domain_name}"
  type    = "A"
  alias {
    name                   = aws_cloudfront_distribution.main.domain_name
    zone_id                = aws_cloudfront_distribution.main.hosted_zone_id
    evaluate_target_health = false
  }
}