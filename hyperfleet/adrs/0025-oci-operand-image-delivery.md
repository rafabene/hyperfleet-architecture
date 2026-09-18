---
Status: Active
Owner: HyperFleet Architecture Team
Last Updated: 2026-09-18
---

# 0025 — Image Delivery for the CAPOCI Controller and the OCI Cloud Controller Manager

## Context

HyperFleet's OCI HostedCluster work needs two images that the OpenShift release payload does not supply: the CAPOCI controller image on the management cluster and the OCI cloud controller manager image in the hosted control plane namespace. [ADR-0021](0021-oci-external-platform.md) deliberately left their delivery open; [HYPERFLEET-1582](https://redhat.atlassian.net/browse/HYPERFLEET-1582) closes that gap so [HYPERFLEET-1547](https://redhat.atlassian.net/browse/HYPERFLEET-1547) and [HYPERFLEET-1552](https://redhat.atlassian.net/browse/HYPERFLEET-1552) can implement it.

This ADR answers one question: where does each image come from in a HyperShift deployment on OCI? The answer must also preserve existing HyperShift override behavior, state the disconnected and mirroring contract for the current OKE management-cluster path, and distinguish the pre-GA source of the defaults from the GA source of the defaults.

## Decision

HyperFleet tells HyperShift which external pullspec to use for each OCI image through image-selection mechanisms HyperShift already supports, and falls back to a digest-pinned default when no override is provided. The source contract is:

| Image | Consumed at | Resolution order | First shipped default | GA default |
|-------|-------------|------------------|-----------------------|------------|
| CAPOCI controller | HyperShift Operator / provider deployment | `hypershift.openshift.io/capi-provider-oci-image` -> `IMAGE_OCI_CAPI_PROVIDER` -> compiled digest-pinned default | Oracle-published CAPOCI image, pinned by manifest-list digest | HyperFleet-owned Konflux build from the same upstream source, pinned by manifest-list digest |
| OCI cloud controller manager | Control Plane Operator / component image resolution | `hypershift.openshift.io/image-overrides` entry `oci-cloud-controller-manager=<pullspec>` -> `IMAGE_OCI_CLOUD_CONTROLLER_MANAGER` -> compiled digest-pinned default | Oracle-published OCI cloud controller manager image, pinned by manifest-list digest | HyperFleet-owned Konflux build from the same upstream source, pinned by manifest-list digest |

HyperFleet does not add a new release-payload tag, a new OCI-specific cloud-controller-manager annotation, or a dedicated Control Plane Operator flag for these images. Moving from the first shipped defaults to the GA defaults changes only the source of the compiled digests, not the resolution contract.

### CAPOCI controller contract

- HyperFleet uses the existing provider-image pattern: HostedCluster annotation `hypershift.openshift.io/capi-provider-oci-image`, then operator environment variable `IMAGE_OCI_CAPI_PROVIDER`, then a compiled digest-pinned default.
- The OCI provider path must be constructible without a required release-payload lookup. Selecting `Platform.Type: OCI` must not fail solely because no payload image tag exists for CAPOCI.
- The CAPOCI default image, vendored CAPOCI version, and shipped CAPOCI CRDs must stay aligned. Bumping any one of them requires bumping the other two.

### OCI cloud controller manager contract

- HyperFleet keeps the user override in the existing `hypershift.openshift.io/image-overrides` annotation as `oci-cloud-controller-manager=<pullspec>`.
- For OCI clusters, HyperFleet automatically supplies an OCI cloud controller manager image to HyperShift through the existing `image-overrides` mechanism. It uses `IMAGE_OCI_CLOUD_CONTROLLER_MANAGER` if set; otherwise it uses the compiled digest-pinned default.
- For the OCI cloud controller manager image, user overrides take precedence over `IMAGE_OCI_CLOUD_CONTROLLER_MANAGER`, which in turn takes precedence over the compiled default.
- HyperFleet provides the OCI cloud controller manager image through HyperShift's existing image-resolution mechanism rather than hardcoding it in the component manifest, so existing override and mirroring behavior continues to apply.
- If HyperFleet cannot resolve an OCI cloud controller manager image, it must fail during rendering rather than later at deployment time.
- The OCI cloud controller manager default must track the hosted cluster's Kubernetes minor. Per Oracle's compatibility matrix, OpenShift 4.20 uses Kubernetes 1.33, so the first default pin is `v1.33.x`.

### Delivery phases

| Phase | Default source | Allowed use |
|-------|----------------|-------------|
| Pre-GA unblocker | Oracle-published images, pinned by manifest-list digest | Unblock [HYPERFLEET-1547](https://redhat.atlassian.net/browse/HYPERFLEET-1547) and [HYPERFLEET-1552](https://redhat.atlassian.net/browse/HYPERFLEET-1552) before HyperFleet owns the build pipeline |
| GA / released OCI install path | HyperFleet-owned Konflux builds from the same Apache-2.0 sources, pinned by manifest-list digest | Required for released OCI support |

Phase 1 and Phase 2 do not represent different user-facing contracts. They differ only in who publishes the default images and whether the defaults satisfy HyperFleet's Konflux and Enterprise Contract release requirements.

### Disconnected install contract

For disconnected OCI installations, customers must mirror both the CAPOCI and OCI cloud controller manager images to a registry they can reach. HyperFleet does not infer those mirror locations; the install path must provide them through the existing override mechanisms when the shipped defaults are not directly reachable.

- For the OCI cloud controller manager image, customers can either configure HyperShift's existing registry-rewrite path or set an explicit image override. If a registry rewrite is configured, it applies to this image.
- For the CAPOCI image, customers must set an explicit image override to the mirrored pullspec. Registry rewrite is not the contract for this image.
- Any explicit override used for disconnected installation must itself be a digest-pinned pullspec.
- Any HyperFleet install artifact that can deploy these OCI operands must list the shipped default images by digest in its image inventory so disconnected users know exactly which images to mirror. Customer-selected override images are additional installation inputs and are not inferred from that inventory.

The current OCI management-cluster path targets OKE rather than an OpenShift management cluster ([HYPERFLEET-1540](https://redhat.atlassian.net/browse/HYPERFLEET-1540), prototype evidence in [HYPERFLEET-1592](https://redhat.atlassian.net/browse/HYPERFLEET-1592)), so HyperFleet cannot make OpenShift-node-specific image redirection the general disconnected contract for both images.

### Bump validation contract

- A CAPOCI image bump is valid only if the vendored CAPOCI version, the shipped CAPOCI CRDs, and the default image digest stay aligned.
- An OCI cloud controller manager image bump is valid only if the selected OCI cloud controller manager minor still matches the hosted cluster's Kubernetes minor, the default digest is updated in the `image-overrides` path above, and tests still prove worker initialization plus `LoadBalancer` service behavior.
- Any default digest change must preserve the same precedence rules, the same disconnected behavior, and the same failure behavior when the OCI cloud controller manager image key is missing.
- The implementing stories and release artifacts own the exact digests and test evidence. This ADR owns the rule for choosing and validating them.

## Consequences

**Gains:**

- Answers the spike directly: both OCI images have an explicit source contract instead of an implied "not in the payload" exception.
- Preserves existing HyperShift override surfaces instead of inventing OCI-specific public API.
- Keeps the OCI cloud controller manager in the image-provider path so `--registry-overrides` continues to work for that image.
- Decouples CAPOCI and OCI cloud controller manager image bumps from the OpenShift release payload while still requiring digest-pinned defaults.
- Lets delivery start with Oracle-published digests now and move to HyperFleet-owned Konflux digests before GA without reopening the decision.

**Trade-offs:**

- CAPOCI uses a compiled default rather than a payload-derived tag, so routine image bumps require code changes in `openshift/hypershift`.
- Pre-GA defaults still depend on third-party published images until the HyperFleet-owned rebuilds land.
- Disconnected behavior is asymmetric: registry overrides reach the OCI cloud controller manager automatically but do not reach CAPOCI.
- The two images have different compatibility rules: CAPOCI tracks the vendored provider version and shipped CRDs, while the OCI cloud controller manager tracks the hosted cluster's Kubernetes minor.
- Supporting more than one OpenShift minor will require a version-keyed OCI cloud controller manager default instead of a single compiled default.

## Alternatives Considered

| Alternative | Why Rejected |
|-------------|--------------|
| Add `oci-*` image tags to the OpenShift release payload | The problem to solve is where HyperFleet sources these two OCI operands, not how to make them payload operands. This would couple OCI image bumps to the OpenShift release train and require release-engineering ownership HyperFleet does not control. |
| Add a new `hypershift.openshift.io/oci-cloud-controller-manager-image` annotation | No cloud-controller-manager image annotation exists for other platforms. This would add new public API for one platform while bypassing the `image-overrides` contract users already know. |
| Add a dedicated Control Plane Operator flag for the OCI cloud controller manager image | Reaches the same end state as the `image-overrides` path while adding a new single-platform command-line surface to support forever. |
| Write a hardcoded OCI cloud controller manager pullspec directly into the component manifest | Bypasses the image-provider path and loses `--registry-overrides` rewriting for the OCI cloud controller manager. |
| Require the HyperFleet-owned Konflux rebuild before unblocking implementation | Front-loads supply-chain work and leaves [HYPERFLEET-1547](https://redhat.atlassian.net/browse/HYPERFLEET-1547) and [HYPERFLEET-1552](https://redhat.atlassian.net/browse/HYPERFLEET-1552) blocked longer even though the resolution contract is already clear. |
| Consume Oracle-published images unchanged at GA | Keeps released OCI support on third-party published images outside HyperFleet's Konflux and Enterprise Contract path. |
| Use mutable tags such as `:v0.24.1` and `:v1.33.2` as the defaults | Mutable tags do not satisfy the digest-pinned image inventory and mirroring requirements. |
| Rely on IDMS/ICSP as the primary disconnected mechanism for these two images | The current OCI management-cluster path targets OKE, not an OpenShift management cluster, so HyperFleet cannot make OpenShift-node-specific redirection the contract for these operands. The chosen contract must work with explicit mirrored pullspecs instead. |

## Implementation Implications

- [HYPERFLEET-1547](https://redhat.atlassian.net/browse/HYPERFLEET-1547) implements the CAPOCI provider deployment with the provider override chain above and no mandatory payload lookup.
- [HYPERFLEET-1552](https://redhat.atlassian.net/browse/HYPERFLEET-1552) implements the OCI cloud controller manager `image-overrides` path, preserves registry overrides, and adds the missing-key guard.
- [HYPERFLEET-1411](https://redhat.atlassian.net/browse/HYPERFLEET-1411), [HYPERFLEET-1412](https://redhat.atlassian.net/browse/HYPERFLEET-1412), and [HYPERFLEET-1569](https://redhat.atlassian.net/browse/HYPERFLEET-1569) own the digest-pinned image inventory once HyperShift becomes a HyperFleet-managed OCI bundle surface.
- [HYPERFLEET-1556](https://redhat.atlassian.net/browse/HYPERFLEET-1556) must keep any release-payload alignment rule scoped to payload-derived images, or explicitly exempt these two non-payload operands.

## References

- [HYPERFLEET-1582](https://redhat.atlassian.net/browse/HYPERFLEET-1582) — [SPIKE] Decide image delivery for CAPOCI and the OCI cloud controller manager (this spike).
- [HYPERFLEET-548](https://redhat.atlassian.net/browse/HYPERFLEET-548) — [HO] CAPOCI integration (epic).
- [HYPERFLEET-1539](https://redhat.atlassian.net/browse/HYPERFLEET-1539) — [HO] Control Plane Operator Integration for OCI (epic; owns the OCI cloud controller manager delivery path).
- [HYPERFLEET-1547](https://redhat.atlassian.net/browse/HYPERFLEET-1547), [HYPERFLEET-1552](https://redhat.atlassian.net/browse/HYPERFLEET-1552) — the two delivery stories this ADR unblocks.
- [HYPERFLEET-1546](https://redhat.atlassian.net/browse/HYPERFLEET-1546), [HYPERFLEET-1548](https://redhat.atlassian.net/browse/HYPERFLEET-1548) — CAPOCI CRD shipment and version pinning.
- [HYPERFLEET-1540](https://redhat.atlassian.net/browse/HYPERFLEET-1540), [HYPERFLEET-1592](https://redhat.atlassian.net/browse/HYPERFLEET-1592) — the current OKE management-cluster path and prototype evidence.
- [HYPERFLEET-1411](https://redhat.atlassian.net/browse/HYPERFLEET-1411), [HYPERFLEET-1412](https://redhat.atlassian.net/browse/HYPERFLEET-1412), [HYPERFLEET-1569](https://redhat.atlassian.net/browse/HYPERFLEET-1569) — bundle ownership and digest-pinned image inventory.
- [HYPERFLEET-1556](https://redhat.atlassian.net/browse/HYPERFLEET-1556) — release-payload alignment work that must keep these operands explicitly out of scope.
- [ADR-0021](0021-oci-external-platform.md) — establishes OCI guest-platform behavior and leaves this image-delivery question open.
- [ADR-0014](0014-konflux-build-and-release.md) — HyperFleet's Konflux build and Enterprise Contract release requirements.
- Version compatibility evidence: [OpenShift 4.20 release notes "About this release" (uses Kubernetes 1.33)](https://github.com/openshift/openshift-docs/blob/e011eb7736b2160e3bba770ea7e6526930bc3110/modules/rn-ocp-release-notes-about-this-release.adoc), [OCI cloud controller manager compatibility matrix](https://github.com/oracle/oci-cloud-controller-manager/blob/88a59e3063a8c18b932054ed51958e9639a30628/README.md#compatibility-matrix).
- Pinned HyperShift code references used for the resolution contract (commit `455579ad6b826d8786023490634792cbe75d61ec`): [GCP provider precedence](https://github.com/openshift/hypershift/blob/455579ad6b826d8786023490634792cbe75d61ec/hypershift-operator/controllers/hostedcluster/internal/platform/gcp/gcp.go), [Control Plane Operator `image-overrides` injection](https://github.com/openshift/hypershift/blob/455579ad6b826d8786023490634792cbe75d61ec/control-plane-operator/controllers/hostedcontrolplane/v2/controlplaneoperator/deployment.go), [component-image map construction](https://github.com/openshift/hypershift/blob/455579ad6b826d8786023490634792cbe75d61ec/control-plane-operator/main.go), [image provider](https://github.com/openshift/hypershift/blob/455579ad6b826d8786023490634792cbe75d61ec/control-plane-operator/controllers/hostedcontrolplane/imageprovider/imageprovider.go), [payload lookup failure](https://github.com/openshift/hypershift/blob/455579ad6b826d8786023490634792cbe75d61ec/support/util/imagemetadata.go).
- Oracle upstream sources and supply-chain evidence: [cluster-api-provider-oci](https://github.com/oracle/cluster-api-provider-oci), [oci-cloud-controller-manager](https://github.com/oracle/oci-cloud-controller-manager), [CAPOCI release workflow attests release artifacts](https://github.com/oracle/cluster-api-provider-oci/blob/c93876d025d4ac2ab94cb744a7162bd838b3084c/.github/workflows/release.yaml), [OCI cloud controller manager published build disables provenance](https://github.com/oracle/oci-cloud-controller-manager/blob/88a59e3063a8c18b932054ed51958e9639a30628/Makefile). The OCI cloud controller manager image is published as `cloud-provider-oci` although the repository is `oci-cloud-controller-manager`.
