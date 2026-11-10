# Architecture Summary — AWS Network Hub for Terraform

This repo holds two Terraform root configurations that work as a pair:

| Root config | Deployed into | Purpose |
|---|---|---|
| `/` (repo root) | Central **network hub** account | Shared, org-wide network services: IPAM, Transit Gateway, centralised egress/ingress inspection, centralised VPC interface endpoints, and Route 53 Resolver DNS. |
| `example-spoke-vpc/` | Each **member (spoke)** account | A workload VPC that takes its CIDR from the hub IPAM, attaches to the hub TGW, and uses the hub's DNS and endpoints. |

Both are **environment-aware**. `var.environment` (`dev`, `test`, `preprod`, `prod`) picks one entry from `env_config` in `config.auto.tfvars`. Each environment of the hub is a separate, independent deployment: its own TGW, IPAM pool and root domain. Default region is `eu-west-2`.

---

## 1. High-level topology

```
                                   Internet
                                       │
                         ┌─────────────┴──────────────┐
                         │  IGW (IPv4)   EIGW (IPv6)  │
                         │   internet subnets + NATGW │   ┐
                         │            ▲  │            │   │
                         │            │  ▼            │   │  Inspection VPC
                         │   inspection subnets (NFW) │   │  (network_firewall_vpc)
                         │            ▲  │            │   │
                         │   attachment subnets       │   ┘
                         └────────────┬───────────────┘
                                      │ appliance-mode attachment
 ┌──────────────┐            ┌────────┴─────────┐           ┌──────────────┐
 │ Endpoint VPC │────────────│  Transit Gateway │───────────│   DNS VPC    │
 │ (vpc_endpts) │   shared   │  RTs: prod, dev, │  shared   │ (dns module) │
 └──────────────┘            │       shared     │           └──────────────┘
                             └───┬──────────┬───┘
                    assoc "dev"  │          │ assoc "prod"
                ┌────────────────┘          └────────────────┐
         ┌──────┴───────┐                            ┌───────┴──────┐
         │ Spoke VPC    │                            │ Spoke VPC    │
         │ (non-prod)   │      ✗ blackholed ✗        │ (prod)       │
         └──────────────┘                            └──────────────┘
```

Every VPC (hub and spoke) gets a `/22` from the **IPAM pool** and runs dual-stack (IPv4 + Amazon-provided IPv6 `/56`).

---

## 2. Hub root configuration (`/`)

### Files

| File | Contents |
|---|---|
| `main.tf` | Calls the five modules. Also defines shared IAM and KMS resources (below). |
| `locals.tf` | `local.config` (the chosen env), merged tags, org ARN, AZ names, and the `local.endpoints` map (`com.amazonaws.<region>.<svc>` → `<svc>.<region>.amazonaws.com`). |
| `variables.tf` / `config.auto.tfvars` | `environment`, `env_config` (`ipam_cidr`, `tgw_route_tables`, `root_domain`), `aws_region`, `vpc_endpoints`, `tags`. |
| `data.tf` | Organization, caller identity, available AZs. |
| `provider.tf` | AWS provider `>= 4.4.0`, Terraform `~> 1.1`, `default_tags`. |
| `backend.tf` | HTTP, Consul and S3+DynamoDB backend examples, all commented out (state is local by default). |
| `outputs.tf` | Debug outputs, all commented out. |

### Shared resources defined in the root `main.tf`

- **`aws_iam_role.central_network`** (`<env>_network_automation_role`). Spoke deployments assume this role through the `aws.network_hub` provider alias. Trust is limited to principals in the same AWS Organization (`aws:PrincipalOrgID`). Its policy allows TGW route-table association and propagation, SSM/KMS reads (for the IPAM pool ID), and Route 53 PHZ association and record changes.
- **`aws_iam_role.flow_logs`**: the VPC Flow Logs service role, passed to every hub VPC module.
- **`aws_kms_key.log_key`**: a CMK with rotation enabled, used to encrypt all CloudWatch log groups (flow logs and firewall logs).

### Module wiring / dependency graph

```
ipam ──► org_ipam_pool ─┬──► vpc_endpoints
                        ├──► dns
                        └──► network_firewall_vpc ──► inspection_attachment ──► tgw
tgw ──► tgw, tgw_route_table ──┬──► vpc_endpoints
                               ├──► dns
                               └──► network_firewall_vpc
```

`tgw` and `network_firewall_vpc` depend on each other. `tgw` needs the inspection attachment ID for its default routes, and the inspection VPC needs the TGW to attach to. Terraform resolves this at the resource level, so it isn't a module cycle.

---

## 3. Hub modules

### 3.1 `modules/ipam`: IP address management

**Architecture:** One org-level IPAM operating in the deployment region. It has a private scope and one IPv4 pool, provisioned with the environment's `/10` (`dev` 10.0.0.0/10, `test` 10.64.0.0/10, `preprod` 10.128.0.0/10, `prod` 10.192.0.0/10). Every VPC in the organization for that environment draws a `/22` from this pool, so CIDRs never overlap.

| Resource | Role |
|---|---|
| `aws_vpc_ipam.org_ipam` | IPAM instance |
| `aws_vpc_ipam_scope.private_org_ipam_scope` | Private scope |
| `aws_vpc_ipam_pool.private_org_ipam_pool` + `aws_vpc_ipam_pool_cidr` | IPv4 pool with the env CIDR |
| `aws_ram_resource_share` / `principal_association` / `resource_association` | Shares the pool with the whole Organization |
| `aws_ssm_parameter.ipam_pool_id` (`/ipam/pool/id`, SecureString) | Publishes the pool ID so spokes can find it |

- **Inputs:** `ipam_cidr`, `org_arn`, `aws_region`
- **Outputs:** `org_ipam`, `org_ipam_pool`
- **Prerequisite:** IPAM must already be delegated to the network account from the Org management account.

### 3.2 `modules/tgw`: Transit Gateway and segmentation

**Architecture:** One TGW per environment (`Org_TGW_<env>`), shared with the Organization via RAM. It uses `auto_accept_shared_attachments`, and the default route table association/propagation are disabled, so every attachment must be placed explicitly.

There is one TGW route table per entry in `tgw_route_tables` (`prod`, `dev`, `shared`). Each table gets:

1. **Blackhole** for the entire org CIDR (`/10`). This is the default-deny for east-west traffic.
2. **`0.0.0.0/0` and `::/0` → inspection VPC attachment**. All internet-bound traffic goes through the firewall.
3. **Propagated routes** (added by the attaching modules). These are more specific than the blackhole, so they open selected paths.

**Association vs propagation:** the two settings control opposite directions of routing.

| | Association | Propagation |
|---|---|---|
| Question it answers | "Where can I go?" | "Who can reach me?" |
| What it does | Picks the route table used to look up traffic *leaving* the attachment | Adds the attachment's CIDR as a route *to* it in the target route table(s) |
| How many per attachment | Exactly **one** | **Many** |
| Terraform resource | `aws_ec2_transit_gateway_route_table_association` | `aws_ec2_transit_gateway_route_table_propagation` (usually with `for_each`) |

Both are needed for two VPCs to talk. For A → B, A's associated table must contain B's CIDR, which means B propagates into it. The return path needs the reverse. Propagated routes are more specific than the `/10` blackhole, so they win. The model is "deny everything inside the org, then open paths with propagation."

Segmentation result:

| Attachment | Associated with RT | Propagates into | Effect |
|---|---|---|---|
| Endpoint / DNS / Inspection VPCs | `shared` | `prod`, `dev`, `shared` | Reachable from every environment |
| Non-prod spoke | `dev` | `shared`, `dev` | Can reach shared services and other dev spokes, not prod |
| Prod spoke | `prod` | `shared`, `prod` | Can reach shared services and other prod spokes, not dev |

- **Inputs:** `environment`, `org_arn`, `cidr`, `inspection_attachment`, `tgw_route_tables`, `az_names` (unused)
- **Outputs:** `tgw` (ID), `tgw_route_table` (map name → RT ID)

### 3.3 `modules/network_firewall_vpc`: centralised ingress/egress inspection

**Architecture:** A three-tier inspection VPC (`inspection_vpc`, `/22`) across 3 AZs. Each tier has one `/27` subnet per AZ and its own route table per AZ, so traffic stays AZ-symmetric.

| Tier | Route table contents |
|---|---|
| **Attachment** subnets (TGW ENIs) | `0.0.0.0/0` → NFW endpoint in the same AZ; `::/0` → EIGW |
| **Inspection** subnets (NFW endpoints) | `org CIDR` → TGW; `0.0.0.0/0` → NAT GW (same AZ); `64:ff9b::/96` → NAT GW (DNS64/NAT64); `::/0` → EIGW |
| **Internet** subnets (public, NAT GW) | `0.0.0.0/0` → IGW; `::/0` → EIGW; `org CIDR` → NFW endpoint (return path) |

IPv4 flow: spoke → TGW → attachment subnet → **Network Firewall** → NAT GW → IGW. The TGW attachment has **appliance mode** enabled so both directions of a flow use the same AZ's firewall endpoint.

`locals.tf` builds lookup maps that tie each AZ's route table to that AZ's firewall endpoint (`eni_lookup` from `firewall_status.sync_states`, plus `attachment_rt_lookup` and `internet_rt_lookup`). These maps assume AZ names follow the `<region>a/b/c` pattern.

**Firewall policy (`policy.tf`):**
- Stateless default: forward everything to the stateful engine.
- Stateful rule group `block-domains`: a domain **DENYLIST** on `HTTP_HOST` and `TLS_SNI` (`.facebook.com`, `.twitter.com`), with `HOME_NET` set to the org CIDR.
- Commented-out examples: stateless ICMP drop, and a Suricata rule to drop SSH between spokes.

**Logging:** ALERT and FLOW logs go to the CloudWatch groups `/aws/network-firewall/alerts` and `/aws/network-firewall/flows`, plus VPC Flow Logs. All are KMS-encrypted with 7-day retention.

- **Inputs:** `environment`, `aws_region`, `az_names`, `cidr`, `org_ipam_pool`, `tgw`, `tgw_route_tables`, `kms_key_id`, `iam_role_arn`
- **Outputs:** `inspection_attachment`, `firewall_info`, `route_table`, `eni_map`, `rt_map`

### 3.4 `modules/vpc_endpoints`: centralised interface endpoints

**Architecture:** A shared `endpoint_vpc` (`/22`) hosts one **Interface VPC endpoint** for each service in `vpc_endpoints` (`ec2`, `rds`, `sqs`, `sns`, `ssm`, `logs`, `ssmmessages`, `ec2messages`, `autoscaling`, `ecs`, `athena`). Spokes don't need to pay for their own copies.

- **Subnets:** 3 × `/27` TGW attachment subnets and 3 × `/26` endpoint subnets, all using one route table with `0.0.0.0/0` and `::/0` → TGW.
- **Endpoints per AZ:** `aws_vpc_endpoint.interface` creates **one endpoint per service** (`for_each` over `interface_endpoints`). Each endpoint lists all 3 endpoint subnets, so AWS puts **one ENI in each AZ**. With the default 11 services, that's 11 endpoints × 3 AZs = **33 ENIs**. The endpoint's DNS name resolves to all of its AZ IPs, so clients in any AZ can reach it and it keeps working if one AZ fails.
- **Security group:** `MGMT-VPC-Endpoints-Traffic-SG` allows TCP 443 from the org CIDR.
- **DNS:** Endpoints are created with `private_dns_enabled = false`. Instead, the module creates a **Private Hosted Zone per service** named after the public service hostname (e.g. `ssm.eu-west-2.amazonaws.com`), with an alias A record pointing at the endpoint. Spoke VPCs are associated with these PHZs later, from the spoke side. That's why the PHZ ignores changes to `vpc`. As a result, spokes resolve AWS API hostnames to the central endpoint IPs and reach them across the TGW.
- **TGW:** Associated with `shared` and propagated to all route tables.
- **Logging:** VPC Flow Logs → `endpoint_vpc` log group.

**How centralization works:** the endpoints exist only in the hub. Spokes reach them through three pieces working together:
1. **DNS:** each spoke associates its VPC with the hub's per-service private hosted zones (`endpoint_phz` in `example-spoke-vpc/modules/dns/dns.tf`). Inside the spoke, `ssm.<region>.amazonaws.com` then resolves to the central endpoint's private IPs.
2. **Network:** the spoke's default route goes to the TGW. The endpoint VPC propagates into every TGW route table, so the spoke's TGW table has a route to it.
3. **Security group:** port 443 is allowed from the whole org `/10` CIDR.

The cost benefit is paying for the ENIs once in the hub instead of in every spoke.

**Exceptions and trade-offs:**
- **Local endpoints in spokes:** spokes can still create their own endpoints. The default `vpc_endpoints = ["s3"]` puts an S3 interface endpoint *in the spoke itself*, with a private hosted zone that covers only that VPC. The default design is mostly centralized, with S3 kept local.
- **Cross-AZ traffic:** DNS returns all three ENI IPs, so a client may connect to an ENI in a different AZ. That traffic can cross AZs through the TGW and the endpoint VPC, adding a little latency and data-transfer cost.
- **Data-processing charges:** central endpoint traffic pays TGW data-processing on top of endpoint data-processing. For heavily used services, a local endpoint can work out cheaper above a certain spoke traffic volume.

- **Inputs:** `environment`, `az_names`, `cidr`, `interface_endpoints`, `org_ipam_pool`, `tgw`, `tgw_route_tables`, `kms_key_id`, `iam_role_arn`
- **Outputs:** none

### 3.5 `modules/dns`: Route 53 Resolver hub

**Architecture:** A shared `dns_vpc` (`/22`), laid out like the endpoint VPC (3 × `/27` attachment and 3 × `/26` endpoint subnets, default routes → TGW).

| Resource | Role |
|---|---|
| `aws_route53_zone.root_private` | Root private zone for the environment (e.g. `network-dev.internal`), associated with the DNS VPC |
| `aws_route53_resolver_endpoint.inbound` / `.outbound` | Resolver endpoints with one IP per endpoint subnet; SG `Network-DNS-Traffic-SG` allows TCP+UDP 53 from the org CIDR |
| `aws_route53_resolver_rule.fwd` | FORWARD rule for `root_domain` via the outbound endpoint |
| `aws_route53_resolver_rule_association.org_dns` | Associates the rule with the DNS VPC |
| `aws_ram_resource_share` (`r53r-org-share`) | Shares the resolver rule with the Organization so spokes can associate it |

**How resolution works across the org:** Each spoke associates the shared FORWARD rule, so its queries for `*.<root_domain>` go to the hub resolver. Each spoke also creates `<account-id>.<root_domain>` and associates that zone with the hub DNS VPC. The hub resolver can therefore answer for every account's subdomain, which gives org-wide private DNS.

- **Inputs:** `environment`, `org_arn`, `cidr`, `az_names`, `interface_endpoints` (unused), `org_ipam_pool`, `tgw`, `tgw_route_tables`, `root_domain`, `kms_key_id`, `iam_role_arn`
- **Outputs:** none

---

## 4. Spoke configuration (`example-spoke-vpc/`)

### Root

- **Two providers:** the default `aws` provider, using the spoke account's credentials, and `aws.network_hub`, which assumes `arn:aws:iam::<hub>:role/<env>_network_automation_role` for the hub-side resources.
- **`data.tf`:** Finds hub resources by tag through `aws.network_hub`: the TGW `Org_TGW_<env>`, the TGW route tables listed in `env_config.tgw_route_tables`, and the route table to associate with (`dev` for any non-prod env, `prod` for prod).
- **`env_config`:** `network_hub_account_number` (blank, you must fill it in), `tgw_route_tables` (`["shared","dev"]` for non-prod, `["shared","prod"]` for prod), and `root_domain`.
- **Variables:** `vpc_endpoints = ["s3"]` (local endpoints) and `centralised_vpc_endpoints` (hub endpoints to consume), plus `vpc_name` and `az_count`.
- **Provider version:** AWS `~> 3.0` (the hub uses `>= 4.4.0`).

### 4.1 `modules/network`: spoke VPC

| Component | Details |
|---|---|
| VPC | `<vpc_name>_vpc`. CIDR is a `/22` from the hub IPAM pool, whose ID is read from SSM `/ipam/pool/id` via the hub role. Dual-stack. |
| Subnets | 3 × `/27` **endpoint** subnets (also used for the TGW attachment) and 3 × `/26` **app** subnets |
| Routing | One route table: `0.0.0.0/0` and `::/0` → TGW (no local NAT or IGW; egress goes through the hub). An EIGW is created but isn't routed. |
| TGW | Attachment in the spoke account. Hub-side association with the env RT and propagation into the env + `shared` RTs, both done through `aws.network_hub`. |
| Local endpoints | Interface endpoints for `vpc_endpoints` (default `s3`) with SG 443 from the VPC CIDR, plus a PHZ and alias record per service (same pattern as the hub) |
| Logging | Its own flow-log IAM role, KMS key, and CloudWatch group (90-day retention) |

- **Outputs:** `vpc_id`

### 4.2 `modules/dns`: spoke DNS integration

| Resource | Role |
|---|---|
| `aws_route53_zone.delegated_private` | `<account-id>.<root_domain>` PHZ attached to the spoke VPC |
| `aws_route53_record.ns_record` (hub) | NS record for the subdomain in the hub root zone |
| `aws_route53_vpc_association_authorization` + `aws_route53_zone_association` | Cross-account association of the spoke PHZ with the hub `dns_vpc` |
| `aws_route53_resolver_rule_association.root_domain` | Associates the RAM-shared FORWARD rule with the spoke VPC |
| `endpoint_phz` authorization + association | Associates the spoke VPC with each hub endpoint PHZ (e.g. `ssm.eu-west-2.amazonaws.com`), so AWS API calls resolve to the central endpoints |

---

## 5. End-to-end flows

| Flow | Path |
|---|---|
| **Spoke → Internet (IPv4)** | Spoke RT → TGW (env RT `0.0.0.0/0`) → inspection attachment subnet → **NFW** → NAT GW → IGW |
| **Internet → spoke (return)** | IGW → internet subnet (`org CIDR` → NFW) → **NFW** → inspection subnet (`org CIDR` → TGW) → spoke |
| **Spoke → AWS API (e.g. SSM)** | Hub PHZ resolves `ssm.<region>.amazonaws.com` to the central endpoint ENI → TGW → endpoint VPC |
| **Spoke → spoke, same env** | TGW env RT has the propagated route → direct (not inspected) |
| **Dev ↔ prod** | No propagated route → matches the org-CIDR blackhole → dropped |
| **Private DNS** | Spoke → shared FORWARD rule → hub resolver → zone for `<acct>.<root_domain>` associated with the DNS VPC |

---

## 6. Prerequisites (from the READMEs)

- An AWS Organization with RAM sharing enabled: `aws ram enable-sharing-with-aws-organization`
- IPAM delegated to the network account: `aws ec2 enable-ipam-organization-admin-account --delegated-admin-account-id <id>`
- Terraform `~> 1.1`
- Deploy the hub first, then spokes, with `environment` set the same on both sides

---

## 7. Review observations

Things I noticed while reading the code. They are worth checking before using this beyond a demo:

1. **Spoke AZ count mismatch:** `example-spoke-vpc` defaults to `az_count = 2` (`slice(..., 0, var.az_count)`), but `modules/network/locals.tf` always reads `var.az_names[2]`. With the default, this looks like an index-out-of-range error at plan time. Either set `az_count = 3` or make the subnet maps dynamic.
2. **Spoke provider pin:** The spoke pins the AWS provider to `~> 3.0` but uses subnet arguments such as `enable_resource_name_dns_a_record_on_launch` and `enable_dns64`, which I believe arrived in provider v4.x. It may need the same `>= 4.4.0` constraint as the hub.
3. **IPv6 egress skips the firewall:** In the inspection VPC, the attachment subnets route `::/0` straight to the EIGW, so IPv6 internet traffic is never inspected by Network Firewall. Only IPv4 (and NAT64) traffic is.
4. **East-west traffic isn't inspected:** Spoke-to-spoke traffic in the same environment uses propagated TGW routes and never passes through the firewall. Cross-env traffic is blackholed rather than inspected. The commented-out "drop SSH between spokes" rule wouldn't take effect unless the TGW routing changes.
5. **Resolver forward rule targets:** `aws_route53_resolver_rule.fwd` forwards to the **outbound** endpoint's own IPs. The usual pattern forwards to the **inbound** endpoint IPs. Please verify that resolution of `<root_domain>` from spokes behaves as intended.
6. **Automation role trust:** The `central_network` role trusts `*` within the Org, plus a `StringNotEqualsIgnoreCase aws:RequestTag/automation = "true"` condition. That condition is unusual: it permits any request that does *not* carry the tag. Checkov's warning (`CKV_AWS_60`) is suppressed with the note "for sample only". It should be tightened for production.
7. **Unused inputs:** `tgw.az_names` and `dns.interface_endpoints` are passed in but never used. `vpc_endpoints` and `dns` have no outputs.
8. **Single region, fixed 3 AZs** in all hub VPC modules, and the subnet keys are hard-coded (`az2a`/`az2b`/`az2c`, or `<region>a/b/c` in the firewall module).
9. **Log retention** is 7 days on the hub and 90 days on spokes. Adjust to your compliance needs.
