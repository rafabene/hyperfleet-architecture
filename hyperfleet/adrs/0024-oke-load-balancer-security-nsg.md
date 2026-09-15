---
Status: Proposed
Owner: HyperFleet Engineering
Last Updated: 2026-09-15
---

# 0024 — Dedicated Network Security Group for OKE Load Balancer Traffic

## Context

HyperFleet's OCI CI stack provisions a VCN and OKE (Oracle Container Engine for Kubernetes) cluster via Terraform, mirroring the existing Terraform in `hyperfleet-infra`.

Every cloud-hosted Kubernetes cluster runs a **Cloud Controller Manager (CCM)**: the control-plane component that talks to the cloud provider's API on the cluster's behalf, so cluster resources (nodes, `LoadBalancer` services, routes) map to real cloud infrastructure. On OKE, Oracle supplies `oci-cloud-controller-manager`. When a Kubernetes `LoadBalancer` service is created, the OCI CCM provisions an OCI load balancer and, by default, edits the security list of the subnet it places that load balancer in — opening the ingress and health-check rules the service needs. During validation, the CCM removed a Terraform-owned rule from that shared security list, producing a `terraform plan` diff (drift) with no code change on either side.

Two components would then be writing to the same security list: Terraform (declaring the baseline rules for node and control-plane traffic) and the OCI CCM (declaring per-service load balancer rules). Whichever writes last wins, and every load-balancer create/delete cycle risks clobbering the other's state.

## Decision

HyperFleet assigns each OKE-managed load balancer a **dedicated Network Security Group (NSG)**, separate from the security list(s) Terraform owns for node and control-plane traffic. The NSG is attached to load balancer services via the `oci.oraclecloud.com/oci-network-security-groups` service annotation.

Terraform creates the NSG as an empty container resource and owns its existence. The OCI CCM associates annotated `LoadBalancer` services with the NSG through `oci.oraclecloud.com/oci-network-security-groups` — an NSG in OCI applies to the VNICs of the resources placed into it, not to a subnet, so this association happens per load balancer, not through Terraform. Terraform does not declare or track the ingress/egress rules inside the NSG. This isolates the two writers to disjoint resources: Terraform never reconciles rules inside the LB-dedicated NSG, and the CCM never touches the security list(s) Terraform manages for everything else.

The alternative was `security-list-management-mode: None`, which turns the CCM's automatic rule management off entirely and puts every load-balancer rule under Terraform. That was rejected: the CCM does not just open a static, known port — it computes the health-check port, protocol, and `loadBalancerSourceRanges` per service from the service spec, and OKE clusters in this environment have `LoadBalancer` services created and destroyed continuously by CI/e2e runs. Fully-Terraform-owned rules would mean hand-writing that logic and updating Terraform for every new or changed service, which both defeats the "no plan diff" acceptance criteria and is a standing maintenance burden the dedicated-NSG approach avoids entirely by letting the CCM keep doing what it already does, just in a resource Terraform doesn't touch.

## Consequences

**Gains:**

- Creating and deleting a `LoadBalancer` service produces no `terraform plan` diff — the CCM's rule changes land in a resource Terraform does not inspect.
- The CCM's existing per-service rule logic (health-check port, protocol, `loadBalancerSourceRanges`) keeps working automatically; HyperFleet does not need to replicate it.
- Scales to the dynamic create/destroy pattern of the CI and e2e environment, where `LoadBalancer` services come and go per test run without any Terraform change.

**Trade-offs:**

- The rules inside the LB NSG are not visible in `terraform plan`/`terraform show` — auditing them requires querying OCI directly (console or CLI), not the Terraform state.
- Every `LoadBalancer` service manifest must carry the `oci.oraclecloud.com/oci-network-security-groups` annotation pointing at the dedicated NSG; a service missing the annotation falls back to the CCM's default behavior against the shared security list, reintroducing drift risk for that one service.

## Alternatives Considered

| Alternative | Why Rejected |
|-------------|--------------|
| **`security-list-management-mode: None`, rules fully owned by Terraform** | Requires reimplementing the CCM's per-service rule logic (health-check port, protocol, source ranges) by hand in Terraform for every `LoadBalancer` service. In an environment where services are created and destroyed dynamically by CI/e2e runs, this means a Terraform change on every new service — the opposite of the "no plan diff" goal — and is brittle to service-spec changes. |
| **Leave default behavior, tolerate drift** | Fails the acceptance criteria directly; a Terraform-owned rule was already observed being removed by the CCM during validation, and repeated drift undermines confidence in `terraform plan` as a source of truth. |

---

## References

- **Story:** [HYPERFLEET-1570 — Own load balancer security rules for OKE-created load balancers](https://redhat.atlassian.net/browse/HYPERFLEET-1570)
- **Epic:** [HYPERFLEET-1542 — OCI Deployment Infrastructure and CI Environment](https://redhat.atlassian.net/browse/HYPERFLEET-1542)
- **External resources:**
  - [OCI Container Engine for Kubernetes — Security Best Practices](https://docs.oracle.com/en-us/iaas/Content/ContEng/Tasks/contengbestpractices_topic-Security-best-practices.htm) — Oracle's own guidance recommends dedicated NSGs over shared security lists for workload traffic, which this ADR follows.
