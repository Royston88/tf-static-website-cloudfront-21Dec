#S3 Bucket
resource "aws_s3_bucket" "static_bucket" {
  bucket        = "royston.sctp-sandbox.com"
  force_destroy = true
}

#Block Public access
resource "aws_s3_bucket_public_access_block" "disable_public_access" {
  bucket                  = aws_s3_bucket.static_bucket.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

#S3 Bucket Policy
resource "aws_s3_bucket_policy" "cloudfront_policy" {
  bucket = aws_s3_bucket.static_bucket.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudFrontServicePrincipal"
        Effect = "Allow"
        Principal = {
          Service = "cloudfront.amazonaws.com"
        }
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.static_bucket.arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.s3_distribution.arn
          }
        }
      }
    ]
  })
  depends_on = [aws_s3_bucket_public_access_block.disable_public_access]
}

resource "aws_s3_bucket_website_configuration" "website" {
  bucket = aws_s3_bucket.static_bucket.id

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "error.html"
  }
}

#Website objects
resource "aws_s3_object" "index" {
  bucket       = aws_s3_bucket.static_bucket.id
  key          = "index.html"
  source       = "${path.module}/website/index.html"
  content_type = "text/html"

  etag = filemd5("${path.module}/website/index.html")
}

resource "aws_s3_object" "error" {
  bucket       = aws_s3_bucket.static_bucket.id
  key          = "error.html"
  source       = "${path.module}/website/error.html"
  content_type = "text/html"
  etag         = filemd5("${path.module}/website/error.html")
}

# For other static assets
resource "aws_s3_object" "assets" {
  for_each     = fileset("${path.module}/website/assets", "**/*")
  bucket       = aws_s3_bucket.static_bucket.id
  key          = "assets/${each.value}"
  source       = "${path.module}/website/assets/${each.value}"
  etag         = filemd5("${path.module}/website/assets/${each.value}")
  content_type = lookup(local.mime_types, split(".", each.value)[length(split(".", each.value)) - 1], "application/octet-stream")
}

# For other images
resource "aws_s3_object" "images" {
  for_each     = fileset("${path.module}/website/images", "*")
  bucket       = aws_s3_bucket.static_bucket.id
  key          = "images/${each.value}"
  source       = "${path.module}/website/images/${each.value}"
  etag         = filemd5("${path.module}/website/images/${each.value}")
  content_type = lookup(local.mime_types, split(".", each.value)[length(split(".", each.value)) - 1], "application/octet-stream")
}

# Define MIME types mapping
locals {
  mime_types = {
    "css"  = "text/css"
    "html" = "text/html"
    "ico"  = "image/vnd.microsoft.icon"
    "js"   = "application/javascript"
    "json" = "application/json"
    "png"  = "image/png"
    "jpg"  = "image/jpeg"
    "jpeg" = "image/jpeg"
    "svg"  = "image/svg+xml"
  }
}

#CloudFront Distribution
resource "aws_cloudfront_distribution" "s3_distribution" {
  provider = aws.us-east-1
  web_acl_id = aws_wafv2_web_acl.waf_acl.arn

  origin {
    domain_name              = aws_s3_bucket.static_bucket.bucket_regional_domain_name
    origin_id                = aws_s3_bucket.static_bucket.id
    origin_access_control_id = aws_cloudfront_origin_access_control.royston_oac.id

  }
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "royston-distribution"
  default_root_object = "index.html"

  aliases    = ["royston.sctp-sandbox.com"]

  # AWS Managed Caching Policy
  default_cache_behavior {
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = aws_s3_bucket.static_bucket.id

    cache_policy_id        = "658327ea-f89d-4fab-a63d-7e88639e58f6"
    viewer_protocol_policy = "redirect-to-https"

  }

  restrictions {
    geo_restriction {
      restriction_type = "whitelist"
      locations        = ["US","SG"]
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate.cert.arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  depends_on = [
    # aws_wafv2_web_acl.waf_acl,
    aws_acm_certificate_validation.cert
  ]
}

#Cloudfront OAC
resource "aws_cloudfront_origin_access_control" "royston_oac" {
  provider = aws.us-east-1
  name                              = "royston_oac"
  description                       = "royston_oac Policy"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

#Route 53
data "aws_route53_zone" "sctp_zone" {
  name = "sctp-sandbox.com"
}

resource "aws_route53_record" "www" {
  zone_id = data.aws_route53_zone.sctp_zone.zone_id
  name    = "royston.sctp-sandbox.com"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.s3_distribution.domain_name
    zone_id                = aws_cloudfront_distribution.s3_distribution.hosted_zone_id
    evaluate_target_health = false
  }
}

#ACM Certificate
resource "aws_acm_certificate" "cert" {
  provider          = aws.us-east-1
  domain_name       = "royston.sctp-sandbox.com"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.cert.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = data.aws_route53_zone.sctp_zone.zone_id
}

resource "aws_acm_certificate_validation" "cert" {
  provider = aws.us-east-1
  certificate_arn         = aws_acm_certificate.cert.arn
  validation_record_fqdns = [for record in aws_route53_record.cert_validation : record.fqdn]
}

#WAF
resource "aws_wafv2_web_acl" "waf_acl" {
  provider = aws.us-east-1

  name        = "royston-static-site-acl"
  description = "royston-webacl"
  scope       = "CLOUDFRONT"


  default_action {
    allow {}
  }

  # Rule to block common web exploits
  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 1

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesCommonRuleSetMetric"
      sampled_requests_enabled   = true
    }
  }

  # Rule to block known bad IP addresses
  rule {
    name     = "AWSManagedRulesAmazonIpReputationList"
    priority = 2

    override_action {
      none {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAmazonIpReputationList"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesAmazonIpReputationListMetric"
      sampled_requests_enabled   = true
    }
  }

  # Rate limiting rule
  rule {
    name     = "RateLimitRule"
    priority = 3

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = 2000
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "RateLimitRuleMetric"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "RoystonStaticSiteWafMetric"
    sampled_requests_enabled   = true
  }
}
