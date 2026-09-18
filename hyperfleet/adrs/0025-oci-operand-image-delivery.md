---
Status: Active
Owner: HyperFleet Architecture Team
Last Updated: 2026-09-18
---

# 0025 — Image Sourcing and Supply Chain for the OCI Operands

## Context

HyperFleet's OCI HostedCluster work needs two images that the OpenShift release payload does not supply: the CAPOCI controller image on the management cluster and the OCI cloud controller manager image in the hosted control plane namespace. [ADR-0021](0021-oci-external-platform.md) deliberately left their delivery open; [HYPERFLEET-1582](https://redhat.atlassian.net/browse/HYPERFLEET-1582) closes that gap so [HYPERFLEET-1547](https://redhat.atlassian.net/browse/HYPERFLEET-1547) and [HYPERFLEET-1552](https://redhat.atlassian.net/browse/HYPERFLEET-1552) can implement it.

This ADR answers one question: where does each image come from in a HyperShift deployment on OCI? It records the source, supply-chain phase split, disconnected-installation contract, and bump-validation rules for those two images. The exact HyperShift resolution mechanism is deliberately deferred to a follow-up ADR while the broader OCI approach is paused.

## Decision

HyperFleet treats both OCI images as non-payload operands. HyperFleet ships a compiled digest-pinned default for each image. For first shipped support, those defaults are Oracle-published manifest-list digests. For GA / released OCI support, those defaults must move to HyperFleet-owned Konflux builds from the same upstream sources. Both images remain outside the OpenShift release payload in either phase.

- CAPOCI controller: the selected image, vendored CAPOCI version, and shipped CAPOCI CRDs must stay aligned. Installation-time overrides are limited to digest-pinned mirrors of that aligned image; they must not change the CAPOCI version independently.
- OCI cloud controller manager: the selected image must remain compatible with the Kubernetes minor of the hosted OpenShift release. OpenShift 4.20 uses Kubernetes 1.33, so the first default pin is `v1.33.x`.

### Delivery phases

| Phase | Default source | Allowed use |
|-------|----------------|-------------|
| Pre-GA unblocker | Oracle-published images, pinned by manifest-list digest | Unblock [HYPERFLEET-1547](https://redhat.atlassian.net/browse/HYPERFLEET-1547) and [HYPERFLEET-1552](https://redhat.atlassian.net/browse/HYPERFLEET-1552) before HyperFleet owns the build pipeline |
| GA / released OCI install path | HyperFleet-owned Konflux builds from the same Apache-2.0 sources, pinned by manifest-list digest | Required for released OCI support |

Phase 1 and Phase 2 do not represent different user-facing contracts. They differ only in who publishes the default images and whether the defaults satisfy HyperFleet's Konflux and Enterprise Contract release requirements.

Released OCI support still needs an explicitly owned follow-up that defines which HyperFleet Konflux components, registry locations, and release wiring publish those GA defaults.

### Disconnected install contract

For disconnected OCI installations, customers must mirror both the CAPOCI and OCI cloud controller manager images to a registry they can reach. HyperFleet does not infer those mirror locations; the install path must provide those mirrored pullspecs when the shipped defaults are not directly reachable.

- Any explicit override used for disconnected installation must itself be a digest-pinned pullspec.
- Any HyperFleet install artifact that can deploy these OCI operands must list the shipped default images by digest in its image inventory so disconnected users know exactly which images to mirror. Customer-selected override images are additional installation inputs and are not inferred from that inventory.

The current OCI management-cluster path targets OKE rather than an OpenShift management cluster ([HYPERFLEET-1540](https://redhat.atlassian.net/browse/HYPERFLEET-1540), prototype evidence in [HYPERFLEET-1592](https://redhat.atlassian.net/browse/HYPERFLEET-1592)), so HyperFleet cannot make OpenShift-node-specific image redirection the general disconnected contract for both images.

### Bump validation contract

- A CAPOCI image bump or override is valid only if the selected image, the vendored CAPOCI version, and the shipped CAPOCI CRDs stay aligned.
- An OCI cloud controller manager image bump or override is valid only if the selected image remains compatible with the hosted cluster's Kubernetes minor and tests still prove worker initialization plus `LoadBalancer` service behavior.
- Any default digest change must preserve the same disconnected behavior and image-inventory requirements.
- The implementing stories and release artifacts own the exact digests and test evidence. This ADR owns the rule for choosing and validating them.

## Consequences

**Gains:**

- Answers the spike directly: both OCI images have an explicit source contract instead of an implied "not in the payload" exception.
- Decouples CAPOCI and OCI cloud controller manager image bumps from the OpenShift release payload while still requiring digest-pinned defaults.
- Lets delivery start with Oracle-published digests now and move to HyperFleet-owned Konflux digests before GA without reopening the decision.

**Trade-offs:**

- Pre-GA defaults still depend on third-party published images until the HyperFleet-owned rebuilds land.
- The two images have different compatibility rules: CAPOCI tracks the vendored provider version and shipped CRDs, while the OCI cloud controller manager tracks the hosted cluster's Kubernetes minor.
- Supporting more than one OpenShift minor will require a version-keyed OCI cloud controller manager default instead of a single compiled default.

## Alternatives Considered

| Alternative | Why Rejected |
|-------------|--------------|
| Consume Oracle-published images unchanged at GA | Keeps released OCI support on third-party published images outside HyperFleet's Konflux and Enterprise Contract path. |
| Use mutable tags such as `:v0.24.1` and `:v1.33.2` as the defaults | Mutable tags do not satisfy the digest-pinned image inventory and mirroring requirements. |

## Implementation Implications

- Released OCI support needs an open, in-scope owner for the HyperFleet Konflux components, registry locations, and release wiring that publish the GA CAPOCI and OCI cloud controller manager defaults.
- Any install artifact that can deploy these operands must inventory the shipped default digests explicitly. Current operator `relatedImages` gates cover only images the operator deploys itself, so these two images can otherwise be omitted silently.
- [HYPERFLEET-1556](https://redhat.atlassian.net/browse/HYPERFLEET-1556) must keep any release-payload alignment rule scoped to payload-derived images, or explicitly exempt these two non-payload operands.

## References

- [HYPERFLEET-1582](https://redhat.atlassian.net/browse/HYPERFLEET-1582) — [SPIKE] Decide image delivery for CAPOCI and the OCI cloud controller manager (this spike).
- [HYPERFLEET-548](https://redhat.atlassian.net/browse/HYPERFLEET-548) — [HO] CAPOCI integration (epic).
- [HYPERFLEET-1539](https://redhat.atlassian.net/browse/HYPERFLEET-1539) — [HO] Control Plane Operator Integration for OCI (epic; owns the OCI cloud controller manager delivery path).
- [HYPERFLEET-1547](https://redhat.atlassian.net/browse/HYPERFLEET-1547), [HYPERFLEET-1552](https://redhat.atlassian.net/browse/HYPERFLEET-1552) — the two delivery stories this ADR unblocks.
- [HYPERFLEET-1546](https://redhat.atlassian.net/browse/HYPERFLEET-1546), [HYPERFLEET-1548](https://redhat.atlassian.net/browse/HYPERFLEET-1548) — CAPOCI CRD shipment and version pinning.
- [HYPERFLEET-1540](https://redhat.atlassian.net/browse/HYPERFLEET-1540), [HYPERFLEET-1592](https://redhat.atlassian.net/browse/HYPERFLEET-1592) — the current OKE management-cluster path and prototype evidence.
- [HYPERFLEET-1556](https://redhat.atlassian.net/browse/HYPERFLEET-1556) — release-payload alignment work that must keep these operands explicitly out of scope.
- [ADR-0021](0021-oci-external-platform.md) — establishes OCI guest-platform behavior and leaves this image-delivery question open.
- [ADR-0014](0014-konflux-build-and-release.md) — HyperFleet's Konflux build and Enterprise Contract release requirements.
- Version compatibility evidence: [OpenShift 4.20 release notes "About this release" (uses Kubernetes 1.33)](https://github.com/openshift/openshift-docs/blob/e011eb7736b2160e3bba770ea7e6526930bc3110/modules/rn-ocp-release-notes-about-this-release.adoc), [OCI cloud controller manager compatibility matrix](https://github.com/oracle/oci-cloud-controller-manager/blob/88a59e3063a8c18b932054ed51958e9639a30628/README.md#compatibility-matrix).
- Oracle upstream sources: [cluster-api-provider-oci](https://github.com/oracle/cluster-api-provider-oci), [oci-cloud-controller-manager](https://github.com/oracle/oci-cloud-controller-manager). The OCI cloud controller manager image is published as `cloud-provider-oci` although the repository is `oci-cloud-controller-manager`.
