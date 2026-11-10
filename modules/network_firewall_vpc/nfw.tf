/* Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
   SPDX-License-Identifier: MIT-0 */

/*
 AWS Network Firewall is a stateful, managed, network firewall and intrusion detection and prevention
 service for your virtual private cloud (VPC). It helps protect your VPCs from common network threats 
 and allows you to define fine-grained network traffic inspection and filtering rules.

 The Network firewall protects the subnets within your VPC by filtering traffic going between the 
 subnets and locations outside of your VPC

 There are 3 resource types involved in setting up AWS Network Firewall:
 1. aws_networkfirewall_firewall: Provides the actual firewall instance that inspects and filters network 
  traffic based on the defined firewall policy in a subnet.
 2. aws_networkfirewall_firewall_policy: Defines the policy used by the firewall, including rule groups and actions for network traffic inspection.
 3. aws_networkfirewall_rule_group: Defines the set of rules used by the firewall to inspect and filter network/vpc traffic.
 4. aws_networkfirewall_logging_configuration: Configures logging for the firewall, including alert and flow logs.
*/

# Create an AWS Network Firewall instance in the inspection VPC inside inspection subnets
resource "aws_networkfirewall_firewall" "inspection_vpc_network_firewall" {
  name                = "NetworkFirewall"
  firewall_policy_arn = aws_networkfirewall_firewall_policy.anfw_policy.arn
  vpc_id              = aws_vpc.inspection_vpc.id

  dynamic "subnet_mapping" {
    for_each = aws_subnet.inspection_subnet

    content {
      subnet_id = subnet_mapping.value.id
    }
  }

}

# Create a Cloudwatch Log Group for AWS Network Firewall Alerts
resource "aws_cloudwatch_log_group" "network_firewall_alert_log_group" {
  name              = "/aws/network-firewall/alerts"
  kms_key_id        = var.kms_key_id
  retention_in_days = 7
  tags = {
    Name = "network-firewall-alerts"
  }
}

# Create a Cloudwatch Log Group for AWS Network Firewall Flows
resource "aws_cloudwatch_log_group" "network_firewall_flow_log_group" {
  name              = "/aws/network-firewall/flows"
  kms_key_id        = var.kms_key_id
  retention_in_days = 7
  tags = {
    Name = "network-firewall-flows"
  }
}

# Confiture AWS Network Firewall logging
resource "aws_networkfirewall_logging_configuration" "network_firewall_alert_logging_configuration" {
  firewall_arn = aws_networkfirewall_firewall.inspection_vpc_network_firewall.arn
  logging_configuration {
    log_destination_config {
      log_destination = {
        logGroup = aws_cloudwatch_log_group.network_firewall_alert_log_group.name
      }
      log_destination_type = "CloudWatchLogs"
      log_type             = "ALERT"
    }
    log_destination_config {
      log_destination = {
        logGroup = aws_cloudwatch_log_group.network_firewall_flow_log_group.name
      }
      log_destination_type = "CloudWatchLogs"
      log_type             = "FLOW"
    }
  }
}
