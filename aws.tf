# Provider configuration
provider "aws" {
  region = "us-east-1" # Change to your preferred region
}

# Use existing HTTP data source to fetch current Imperva IP ranges
data "http" "imperva-ips" {
  # Your existing data block for fetching Imperva IPs
  # This is assumed to already exist in your configuration
}

# Define the AppSync ARN as a variable or local value
locals {
  appsync_arn = "arn:aws:appsync:us-east-1:123456789012:apis/abcdefghijklmnopqrstuvwxyz" # Replace with your actual AppSync ARN
  
  # Parse the IP addresses from the HTTP response
  # Adjust this based on the actual format of your HTTP response
  imperva_ips = jsondecode(data.http.imperva-ips.body).ipRanges
}

# Create IP Set for Incapsula IP ranges
resource "aws_wafv2_ip_set" "incapsula_ip_set" {
  name               = "incapsula-ip-set"
  description        = "IP set containing Imperva Incapsula edge IP ranges"
  scope              = "REGIONAL" # AppSync APIs are regional resources
  ip_address_version = "IPV4"
  
  # Use the IP ranges from the HTTP data source
  addresses = local.imperva_ips

  tags = {
    Name    = "incapsula-ip-set"
    Service = "AppSync"
  }
}

# Create WAF WebACL
resource "aws_wafv2_web_acl" "appsync_waf" {
  name        = "appsync-incapsula-waf"
  description = "WAF to only allow traffic from Incapsula IP ranges for AppSync"
  scope       = "REGIONAL"

  default_action {
    block {} # Block all traffic by default
  }

  # Rule to allow Incapsula IPs
  rule {
    name     = "allow-incapsula-ips"
    priority = 1

    action {
      allow {}
    }

    statement {
      ip_set_reference_statement {
        arn = aws_wafv2_ip_set.incapsula_ip_set.arn
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AllowIncapsulaIPs"
      sampled_requests_enabled   = true
    }
  }
  
  # Optional: Add a rate-based rule as additional protection
  rule {
    name     = "rate-limit-rule"
    priority = 2

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = 1000 # Requests per 5 minutes
        aggregate_key_type = "IP"
        
        scope_down_statement {
          ip_set_reference_statement {
            arn = aws_wafv2_ip_set.incapsula_ip_set.arn
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "RateLimitRule"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "AppSyncWAF"
    sampled_requests_enabled   = true
  }

  tags = {
    Name        = "appsync-incapsula-waf"
    Environment = "Production"
    Service     = "AppSync"
  }
}

# Associate the WebACL with the AppSync API using the existing ARN
resource "aws_wafv2_web_acl_association" "appsync_waf_association" {
  resource_arn = local.appsync_arn
  web_acl_arn  = aws_wafv2_web_acl.appsync_waf.arn
}

# Set up logging for the WAF
resource "aws_cloudwatch_log_group" "waf_logs" {
  name              = "/aws/waf/appsync-incapsula"
  retention_in_days = 30
  
  tags = {
    Name    = "appsync-waf-logs"
    Service = "AppSync"
  }
}

resource "aws_wafv2_web_acl_logging_configuration" "waf_logging" {
  log_destination_configs = [aws_cloudwatch_log_group.waf_logs.arn]
  resource_arn            = aws_wafv2_web_acl.appsync_waf.arn
  
  # Optional: Redact sensitive headers
  redacted_fields {
    single_header {
      name = "authorization"
    }
  }
}
