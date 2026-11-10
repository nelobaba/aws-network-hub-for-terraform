/* Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
   SPDX-License-Identifier: MIT-0 */

/*
  Amazon Route 53 Resolver responds to DNS queries from AWS resources for public records, Amazon VPC-specific DNS names, 
  and Amazon Route 53 private hosted zones, and is available by default in all VPCs.
  It allows you to create inbound and outbound resolver endpoints to manage DNS traffic between your VPCs and on-premises networks. 

  An Amazon VPC connects to a Route 53 Resolver at a VPC+2 IP address.
  A Route 53 Resolver automatically answers DNS queries for: 
  1. Local VPC domain names for EC2 instances (for example, ec2-192-0-2-44.compute-1.amazonaws.com). 
  2. Records in private hosted zones (for example, acme.example.com). 
  3. For public domain names, Route 53 Resolver performs recursive lookups against public name servers on the internet.

  Private hosted zones contain records that specify how you want to route traffic in an Amazon VPC.
  Route53 does not respond to queries which are not originating from the VPC. If EC2 from VPC-2 sends query for 01.demo.internal to VPC-1 + 2 Address, it will not be resolvable.

  AWS has released Route53 Resolver Endpoints that can allow resolution of private hosted zone domains from outside of the VPC.
  Inbound Resolver endpoints allow DNS queries to your VPC from your on-premises network or another VPC. 
  Outbound Resolver endpoints allow DNS queries from your VPC to your on-premises network or another VPC.

  Inbound Endpoint Workflow - 1 
  1. A client in the on-premises data center needs to resolve a DNS query to an AWS resource for the domain dev.example.com. It sends the query to the on-premises DNS resolver. 
  2. The on-premises DNS resolver has a forwarding rule that points queries to dev.example.com to an inbound endpoint. 
  3. The query arrives at the inbound endpoint through a private connection, such as AWS Direct Connect or AWS Site-to-Site VPN, depicted as a virtual gateway.
  4. The inbound endpoint sends the query to Route 53 Resolver at the VPC +2. 5. Route 53 Resolver resolves the DNS query for dev.example.com and returns the 
    answer to the client via the same path in reverse.

  Outbound Endpoint Workflow - 1 
  1. An Amazon EC2 instance needs to resolve a DNS query to the domain internal.example.com. The authoritative DNS server is in the on-premises data center. This DNS query is sent to the VPC+2 in the VPC that connects to Route 53 Resolver. 
  2. A Route 53 Resolver forwarding rule is configured to forward queries to internal.example.com in the on-premises data center. 
  3. The query is forwarded to an outbound endpoint.
  4. The outbound endpoint forwards the query to the on-premises DNS resolver through a private connection between AWS and the data center. The connection can be either AWS Direct Connect or AWS Site-to-Site VPN, depicted as a virtual private gateway. 
  5. The on-premises DNS resolver resolves the DNS query for internal.example.com and returns the answer to the Amazon EC2 instance via the same path in reverse.
*/

resource "aws_route53_zone" "root_private" {
  name = var.root_domain

  vpc {
    vpc_id = aws_vpc.dns_vpc.id
  }
}

resource "aws_security_group" "allow_dns" {
  # Creates security group for use with dns endpoints.
  #checkov:skip=CKV2_AWS_5: Security group attached to DNS R53R Endpoints
  name        = "Network-DNS-Traffic-SG"
  description = "Allow traffic across org to dns endpoints"
  vpc_id      = aws_vpc.dns_vpc.id
  tags = {
    Name = "Network-DNS-Traffic-SG"
  }
}

resource "aws_security_group_rule" "dns_tcp" {
  # Creates Security group rule to allow dns endpoint traffic, attaches to security group created above.
  for_each          = toset(local.dns_proto)
  type              = "ingress"
  from_port         = 53
  to_port           = 53
  protocol          = each.value
  cidr_blocks       = ["${var.cidr}"]
  security_group_id = aws_security_group.allow_dns.id
  description       = "Allow 53 traffic across org to dns endpoints"
}

resource "aws_route53_resolver_endpoint" "inbound" {
  name      = "Org-Inbound-Resolver-Endpoint"
  direction = "INBOUND"

  security_group_ids = [
    aws_security_group.allow_dns.id
  ]

  dynamic "ip_address" {
    for_each = aws_subnet.endpoint_subnet

    content {
      subnet_id = ip_address.value.id
    }
  }

  tags = {
    Environment = var.environment
  }
}
resource "aws_route53_resolver_endpoint" "outbound" {
  name      = "Org-Outbound-Resolver-Endpoint"
  direction = "OUTBOUND"

  security_group_ids = [
    aws_security_group.allow_dns.id
  ]

  dynamic "ip_address" {
    for_each = aws_subnet.endpoint_subnet

    content {
      subnet_id = ip_address.value.id
    }
  }

  tags = {
    Environment = var.environment
  }
}

resource "aws_route53_resolver_rule" "fwd" {
  domain_name          = var.root_domain
  name                 = "root-env"
  rule_type            = "FORWARD"
  resolver_endpoint_id = aws_route53_resolver_endpoint.outbound.id

  dynamic "target_ip" {
    for_each = aws_route53_resolver_endpoint.outbound.ip_address

    content {
      ip = target_ip.value.ip
    }
  }

  tags = {
    Environment = var.environment
  }
}

resource "aws_route53_resolver_rule_association" "org_dns" {
  resolver_rule_id = aws_route53_resolver_rule.fwd.id
  vpc_id           = aws_vpc.dns_vpc.id
}

resource "aws_ram_resource_share" "main" {
  name                      = "r53r-org-share"
  allow_external_principals = false

  tags = {
    Name = "org-r53r-ram-share"
  }
}

# Requires RAM enabled to share with AWS org:
# enable in org master account with 'aws ram enable-sharing-with-aws-organization'
resource "aws_ram_principal_association" "org" {
  principal          = var.org_arn
  resource_share_arn = aws_ram_resource_share.main.arn
}

# Requires RAM enabled to share with AWS org
resource "aws_ram_resource_association" "r53r" {
  resource_arn       = aws_route53_resolver_rule.fwd.arn
  resource_share_arn = aws_ram_resource_share.main.arn
}
