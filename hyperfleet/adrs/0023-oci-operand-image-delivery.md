---
Status: Active
Owner: HyperFleet Architecture Team
Last Updated: 2026-09-10
---

# 0023 — Image Delivery for the CAPOCI Controller and the OCI Cloud Controller Manager

## Context

HyperFleet's CAPOCI integration ([HYPERFLEET-548](https://redhat.atlassian.net/browse/HYPERFLEET-548)) needs two container images that no OpenShift release payload contains, and never will: the **CAPOCI controller** (a Deployment per hosted control plane, on the management cluster) and the **OCI cloud controller manager** (in the hosted control plane namespace). [ADR-0021](0021-oci-external-platform.md) put the OCI CCM in HyperFleet's hands as an operand and explicitly left this open — *"Their images are not in the OpenShift release payload, another question for those stories."* This spike ([HYPERFLEET-1582](https://redhat.atlassian.net/browse/HYPERFLEET-1582)) is that question, and it blocks both delivery stories: [HYPERFLEET-1547](https://redhat.atlassian.net/browse/HYPERFLEET-1547) (deploy CAPOCI from `CAPIProviderDeploymentSpec`) and [HYPERFLEET-1552](https://redhat.atlassian.net/browse/HYPERFLEET-1552) (implement the OCI CCM component).

Every other platform gets both images from the release payload, so there is no pattern to copy wholesale. In upstream HyperShift the two resolve at two different layers with two different mechanics. CAPI provider images resolve in the HyperShift Operator, `annotation > env var > payload`, against the payload keys enumerated in `hypershift-operator/controllers/hostedcluster/internal/platform/platform.go` (`aws-`, `azure-`, `gcp-`, `ibmcloud-`, `openstack-cluster-api-controllers`, `openstack-resource-controller`). Cloud controller manager images resolve in the Control Plane Operator through a **payload-key placeholder** written directly into the asset — `v2/assets/gcp-cloud-controller-manager/deployment.yaml` literally carries `image: gcp-cloud-controller-manager`, which `replaceContainersImageFromPayload` swaps for the real pullspec. OCI is not an OpenShift payload platform: upstream `main` contains no OCI content and `ValidPlatforms` in `cmd/install/install.go` has no `oci` entry, so neither key can ever exist. Deciding both at once, with one precedence users learn once, is what unblocks the two stories.

Two constraints shape the answer beyond the code. First, the management cluster is **vanilla OKE, not OpenShift** ([HYPERFLEET-1540](https://redhat.atlassian.net/browse/HYPERFLEET-1540)); the prototype run on 2026-08-25 brought a platform-OCI HostedCluster on a 4.20.2 payload to 35 running control plane pods in six minutes on OKE ([HYPERFLEET-1592](https://redhat.atlassian.net/browse/HYPERFLEET-1592)). IDMS/ICSP never rewrites individual component image references — that redirect is a CRI-O behaviour on OpenShift nodes — so the usual disconnected story does not apply here and has to be decided explicitly. Second, HyperFleet ships through Konflux under Enterprise Contract policy `app-interface-standard` ([ADR-0014](0014-konflux-build-and-release.md)). Oracle's images are Apache-2.0 and genuinely multi-arch, but carry no cosign signature, no SBOM and no SLSA provenance — the CCM Makefile passes `--provenance false` explicitly, and the CAPOCI build has no attestation steps at all.

## Decision

Both images are delivered **outside the OpenShift release payload**, resolved by one uniform precedence — **per-cluster annotation > operator-level environment variable > compiled digest-pinned default** — using two mechanisms that already exist upstream. No new payload tag, no new cloud-controller-manager annotation, and no new Control Plane Operator flag are introduced.

The two images sit at different layers, so they reach that precedence by different existing routes. Delivery is staged: Oracle's upstream images, digest-pinned, unblock the stories now; a Konflux rebuild is required before GA and changes only the pinned values, not the contract below.

### Resolution contract

**Image A — CAPOCI controller** (HyperShift Operator layer), consumed by [HYPERFLEET-1547](https://redhat.atlassian.net/browse/HYPERFLEET-1547):

| Tier | Reference | Go identifier | File in `openshift/hypershift` |
|------|-----------|---------------|--------------------------------|
| 1 | `hypershift.openshift.io/capi-provider-oci-image` | `ClusterAPIOCIProviderImage` | `api/hypershift/v1beta1/hostedcluster_types.go`, beside `ClusterAPIGCPProviderImage` |
| 2 | `IMAGE_OCI_CAPI_PROVIDER` | `OCICAPIProviderEnvVar` | `support/images/envvars.go` |
| 3 | `ghcr.io/oracle/cluster-api-oci-controller@sha256:…` | `DefaultOCICAPIProviderImage`, read through `GetOCICAPIProviderImage()` | `support/images/envvars.go` |
| — | release payload | **none, ever** | no `oci-cluster-api-controllers` key exists |

Resolution lives in `hypershift-operator/controllers/hostedcluster/internal/platform/oci/oci.go` (`CAPIProviderDeploymentSpec`), mirroring the precedence block in `platform/gcp/gcp.go`. The annotation and environment variable names follow the existing convention exactly; the getter follows the `GetSharedIngressHAProxyImage()` shape.

One correction the GCP reference does not make obvious: the OCI case in `platform/platform.go` must **not** call `GetPayloadImage`. `GetPayloadImageFromRelease` (`support/util/imagemetadata.go`) returns `image does not exist for release` when the key is absent, so copying the GCP registration verbatim would hard-fail every OCI HostedCluster before any image logic ran. Registration reduces to constructing the platform; all image logic stays in `oci.go`.

**Image B — OCI cloud controller manager** (Control Plane Operator layer), consumed by [HYPERFLEET-1552](https://redhat.atlassian.net/browse/HYPERFLEET-1552):

| Tier | Reference | Go identifier | File in `openshift/hypershift` |
|------|-----------|---------------|--------------------------------|
| 1 | `hypershift.openshift.io/image-overrides`, entry `oci-cloud-controller-manager=<pullspec>` | existing `ImageOverridesAnnotation` — **no new API** | `api/hypershift/v1beta1/hostedcluster_types.go` |
| 2 | `IMAGE_OCI_CLOUD_CONTROLLER_MANAGER` | `OCICloudControllerManagerEnvVar` | `support/images/envvars.go` |
| 3 | `ghcr.io/oracle/cloud-provider-oci@sha256:…` | `DefaultOCICloudControllerManagerImage`, read through its getter | `support/images/envvars.go` |

The asset (`v2/assets/oci-cloud-controller-manager/deployment.yaml`) carries the literal payload key `image: oci-cloud-controller-manager`, identical in shape to the GCP asset. The pullspec reaches it as a **synthetic payload tag**: in `v2/controlplaneoperator/deployment.go`, where the Control Plane Operator's `--image-overrides` flag is built, prepend `oci-cloud-controller-manager=<default>` for `Platform.Type: OCI` and append the HostedCluster annotation value after it. `buildComponentImages` (`control-plane-operator/main.go`) splits that comma-separated list into a map in order — last write wins — so the annotation beats the default with no extra precedence code. That flag is constructed in the HyperShift Operator process, so no addition to `mirroredAnnotations` is needed.

This route is chosen over reading a pullspec in the component because it is the only one that stays inside the registry-override channel. `StaticProviderDecorator` appends `--image-overrides` entries as real ImageStream tags; `RegistryMirrorProviderDecorator` then rewrites **every** tag through `registryoverride.Replace`, and `imageprovider.NewWithRegistryOverrides` re-applies it across every component image. A fully-qualified pullspec written straight into the container passes `replaceContainersImageFromPayload` untouched and is never rewritten.

Two guards are mandatory, because a missing synthetic tag fails silently: `ImageExist` records no misses — only `GetImage` appends to `missingImages`, and only that list feeds the `ValidReleaseInfo` condition — so an absent key renders `image: oci-cloud-controller-manager` verbatim and yields `ImagePullBackOff` with no condition and no event. Therefore the operator-side merge is **unconditional** for platform OCI (never gated on the annotation being present), and the component **must error** when `ImageExist("oci-cloud-controller-manager")` is false.

### Version pinning

The rule, not the number — the CAPOCI version itself is owned by [HYPERFLEET-1548](https://redhat.atlassian.net/browse/HYPERFLEET-1548):

| Image | Rule |
|-------|------|
| CAPOCI controller | The image digest MUST correspond to the CAPOCI version in `go.mod`/`vendor` **and** to the CRDs shipped by [HYPERFLEET-1546](https://redhat.atlassian.net/browse/HYPERFLEET-1546). Bumping any one of the three bumps all three. |
| OCI cloud controller manager | The CCM minor MUST equal the hosted cluster's Kubernetes minor, per Oracle's support matrix. OpenShift 4.20 is Kubernetes 1.33, so **v1.33.x** — not the newer v1.35.0. |

References are pinned by **manifest-list (index) digest**, never by tag: tags are mutable, and the digest-pinned `relatedImages` gate ([HYPERFLEET-1412](https://redhat.atlassian.net/browse/HYPERFLEET-1412)) requires digests. Index digests as of 2026-09-10 — all `application/vnd.docker.distribution.manifest.list.v2+json`, all `amd64` + `arm64`:

| Image | Tag | Index digest |
|-------|-----|--------------|
| `ghcr.io/oracle/cluster-api-oci-controller` | v0.24.0 (currently vendored) | `sha256:aece24436d7bba44e2e27006dc824bb9bba1fd48791a3d602345feada171a8d7` |
| `ghcr.io/oracle/cluster-api-oci-controller` | v0.24.1 (latest, 2026-06-25) | `sha256:d0170cda03e0e1014b0a0ed090beb734427ca304d6a2fcdcbd2afd8cbc140db2` |
| `ghcr.io/oracle/cloud-provider-oci` | **v1.33.2** (Kubernetes 1.33 line — the pin) | `sha256:9760809b7161bb58e2d9c5bbdb8c5f788cd6657633898939a24f2e84b1c68476` |
| `ghcr.io/oracle/cloud-provider-oci` | v1.34.2 | `sha256:326c36abea275fe01cf81c42c3b50d811dea788ab458bdb2e86671aaf703ea83` |
| `ghcr.io/oracle/cloud-provider-oci` | v1.35.0 (latest) | `sha256:f228e27f5c5c1c26a3f6eb8e8e32ba4229eec50c3baac1b86c8eb75f5882e6de` |

The fork currently vendors CAPOCI v0.24.0; v0.24.1 exists and is flagged to HYPERFLEET-1548, which decides. A registry query for the index digest must send an `Accept` header listing `application/vnd.oci.image.index.v1+json` and `application/vnd.docker.distribution.manifest.list.v2+json`; without it the registry may answer with a per-architecture child manifest, whose digest is the wrong thing to pin.

One known limitation: a single compiled constant cannot track a moving payload minor. That is acceptable while HyperFleet supports one OpenShift minor. Supporting a second requires a version-keyed default, computed where the payload version is already known.

### Delivery: two phases

| Phase | Source | Gate |
|-------|--------|------|
| 1 — now, unblocks 1547 and 1552 | Oracle's upstream `ghcr.io/oracle/*` images, pinned by index digest | Pre-GA only |
| 2 — **required for GA** | Rebuilt from Apache-2.0 source in Konflux into `quay.io/redhat-services-prod/hyperfleet-tenant/hyperfleet/`, using `docker-build-multi-platform-oci-ta` | cosign signatures, SBOM, SLSA L3, Enterprise Contract `app-interface-standard` |

Both upstream repositories are Apache-2.0, so rebuilding and redistributing is permitted. Phase 1 images cannot satisfy `app-interface-standard` — they have no signature, SBOM or provenance — so they must not be referenced from a released bundle. Both images are multi-arch while HyperFleet's pipelines currently set no `build-platforms` parameter, hence the switch to `docker-build-multi-platform-oci-ta`, which the release pipeline design describes as a one-line change per pipeline file. Konflux digest nudges only fire for images Konflux itself builds, so during Phase 1 these two digests are maintained by hand; nudges begin working only after Phase 2.

Phase 2 changes the values of two constants and the corresponding bundle arguments. It does not change the resolution contract above.

### Disconnected and mirroring

| Lever | Reaches CAPOCI | Reaches OCI CCM | Why |
|-------|----------------|-----------------|-----|
| IDMS/ICSP on the management cluster | No | No | Never rewrites individual component image references; that redirect is CRI-O on OpenShift nodes, and the management cluster is vanilla OKE |
| `--registry-overrides` | **No** | **Yes** | The operator applies overrides to payload and release lookups only; the CCM's synthetic tag is rewritten by `RegistryMirrorProviderDecorator` and again by `imageprovider.NewWithRegistryOverrides` |
| Environment variable / annotation pullspec | Yes | Yes | Used verbatim — in a mirrored environment, set the already-mirrored pullspec |
| `relatedImages` + `RELATED_IMAGE_*` + Konflux nudges | Yes | Yes | HyperFleet's existing operand-pinning pattern, already CI-gated by [HYPERFLEET-1412](https://redhat.atlassian.net/browse/HYPERFLEET-1412) |

That asymmetry is real and must be documented for operators, not glossed: `--registry-overrides` rewrites the CCM image but **not** the CAPOCI image. In a mirrored environment `IMAGE_OCI_CAPI_PROVIDER` must be set to the already-mirrored pullspec.

Both images MUST appear, digest-pinned, in the bundle's `.spec.relatedImages`, so a disconnected customer can enumerate and mirror them. This reuses HyperFleet's proven pattern rather than inventing an OCI-specific one: a compiled default in the operator, an override environment variable patched onto the Deployment, digest-pinned build arguments maintained by Konflux nudges, and a bundle step that rewrites `.spec.relatedImages`. Note that the HyperShift Operator is not currently a HyperFleet operand, so these environment variables are set by whatever installs it; the `--image-refs` path only populates environment variables for tags present in an OpenShift release ImageStream and will never populate these two.

## Consequences

**Gains:**

- Unblocks HYPERFLEET-1547 and HYPERFLEET-1552 immediately, with one precedence rule that applies to both images, so operators learn it once.
- Reuses two mechanisms already in upstream `main`. The net-new upstream surface is one annotation, two environment variables and two constants — each shaped exactly like an existing one — plus a new asset and component that mirror GCP's.
- The cloud controller manager image inherits `--registry-overrides` rewriting for free, which is the only mirroring lever available on a non-OpenShift management cluster. A new annotation or a compiled fallback in the component would have forfeited it.
- The operator re-merges its default on every reconcile, so an administrator editing `image-overrides` for an unrelated key cannot accidentally drop the CCM entry.
- Digest pinning makes both images enumerable for `relatedImages` and mirrorable, satisfying the HYPERFLEET-1412 gate.
- Phase 2 changes only constant values, so productisation does not reopen the contract or touch the delivery stories.

**Trade-offs:**

- A compiled default deviates from every existing CAPI provider, all of which hard-error when no payload image is found. It is accepted only because no OCI payload tag can exist; the precedent is narrow (`DefaultSharedIngressHAProxyImage`, `DefaultKarpenterProviderAWSImage`). The cost is that a routine image bump becomes a code change in `openshift/hypershift`, on that repository's review cadence.
- Phase 1 ships images with no signature, SBOM or provenance. They cannot pass `app-interface-standard`, so GA depends on Phase 2 landing.
- `--registry-overrides` reaches one image and not the other — an asymmetry operators must be told about, and one more thing a disconnected runbook has to get right.
- A missing synthetic tag is silent (`ImageExist` records no misses, so no `ValidReleaseInfo` condition is raised), which is why an explicit guard is mandatory rather than optional.
- The two images skew against different things — CAPOCI against the vendored version and shipped CRDs, the CCM against the hosted cluster's Kubernetes minor — so both need bump discipline the release payload would otherwise have provided.
- The single compiled CCM default does not scale to more than one supported OpenShift minor without further work.

## Alternatives Considered

| Alternative | Why Rejected |
|-------------|--------------|
| A new `hypershift.openshift.io/oci-cloud-controller-manager-image` annotation, symmetric with the CAPOCI side | No cloud-controller-manager image annotation exists for any platform, so this is net-new API. A control-plane-side read would additionally require adding it to `mirroredAnnotations`. Worst of all, a fully-qualified pullspec written into the container bypasses the image provider, so `--registry-overrides` would never rewrite it — removing the only mirroring lever on OKE. |
| A new Control Plane Operator flag `--oci-cloud-controller-manager-image`, shaped like `--socks5-proxy-image` | A strict superset of the chosen change — new flag, new `buildComponentImages` parameter, *plus* the same call-site edit — for an identical end state in the component image map. It adds single-platform command-line surface that upstream would maintain forever. |
| A compiled fallback branch in `replaceContainersImageFromPayload`, following the Karpenter precedent | That branch assigns the constant directly to the container, bypassing the image provider, so it receives no registry-override rewriting. On a vanilla OKE management cluster that removes the only mirroring lever. |
| Add `oci-*` tags to the OpenShift release payload | OCI is not an OpenShift payload platform. This needs release-engineering ownership HyperFleet does not have, and would couple OCI image bumps to the OpenShift release train. |
| Consume Oracle's images unchanged at GA | No cosign signature, no SBOM, no SLSA provenance (the CCM Makefile sets `--provenance false`). Fails the `app-interface-standard` Enterprise Contract policy fixed by [ADR-0014](0014-konflux-build-and-release.md). |
| Complete the Konflux rebuild before unblocking 1547 and 1552 | Requires switching to `docker-build-multi-platform-oci-ta`, new Konflux Applications and Components, and ReleasePlanAdmission and constraints updates — supply-chain work measured in weeks that would idle two blocked stories. Sequenced as Phase 2 instead. |
| `oc-mirror` `additionalImages` with generated IDMS/ICSP applied to the management cluster | IDMS/ICSP never rewrites individual component image references; that redirect is a CRI-O behaviour on OpenShift nodes, and the management cluster is vanilla OKE. The mechanism would appear to be configured and silently do nothing. |
| Tag-based references such as `:v0.24.1` and `:v1.33.2` | Mutable, not mirrorable by digest, and incompatible with the digest-pinned `relatedImages` CI gate from HYPERFLEET-1412. |
| Pin the CAPOCI version in this ADR | Owned by [HYPERFLEET-1548](https://redhat.atlassian.net/browse/HYPERFLEET-1548). This ADR fixes the rule binding image digest, `go.mod` version and shipped CRDs together, and records the candidate digests; the value is that spike's call. |

## Follow-up Work

Recorded here rather than filed, so the GA gate is explicit and nothing is lost:

- Switch the HyperFleet Konflux pipelines to `docker-build-multi-platform-oci-ta` (prerequisite for both rebuilds).
- Konflux Application and Component to rebuild `cluster-api-provider-oci` from source into the HyperFleet tenant — **required for GA**.
- Konflux Application and Component to rebuild `oci-cloud-controller-manager` from source into the HyperFleet tenant — **required for GA**.
- Add both rebuilt components to the HyperFleet ReleasePlanAdmission and service constraints in `konflux-release-data`.
- Set `IMAGE_OCI_CAPI_PROVIDER` and `IMAGE_OCI_CLOUD_CONTROLLER_MANAGER`, digest-pinned, on the HyperShift Operator Deployment from the HyperFleet install path, and add both images to the bundle's `relatedImages` (extends [HYPERFLEET-1411](https://redhat.atlassian.net/browse/HYPERFLEET-1411), [HYPERFLEET-1569](https://redhat.atlassian.net/browse/HYPERFLEET-1569), [HYPERFLEET-1412](https://redhat.atlassian.net/browse/HYPERFLEET-1412)).
- Disconnected runbook and end-to-end test: mirror both images, set `--registry-overrides`, and prove an OCI hosted cluster comes up on a restricted OKE cluster — including the documented CAPOCI asymmetry.
- CCM/Kubernetes skew guard, plus a version-keyed default for when a second OpenShift minor is supported.
- Confirm that [HYPERFLEET-1556](https://redhat.atlassian.net/browse/HYPERFLEET-1556) (control plane operator and release payload alignment) explicitly exempts non-payload operands such as these two.

### Tests the delivery stories inherit

1. CAPOCI precedence: annotation beats environment variable beats compiled default, and the compiled default alone yields a working `DeploymentSpec` with no error.
2. An OCI HostedCluster with no payload tag does not error out of platform construction.
3. For platform OCI, `--image-overrides` contains the default when the annotation is empty and the administrator's value wins when the annotation sets the same key; other platforms render byte-identically to today.
4. The rendered OCI CCM container image is the injected pullspec, not the literal key.
5. With the synthetic tag absent, the component errors rather than rendering `image: oci-cloud-controller-manager`.
6. `--registry-overrides` rewrites the CCM image and does not rewrite the CAPOCI image — the asymmetry is asserted, not assumed.
7. Both images appear digest-pinned in the bundle's `relatedImages`.

## References

- [HYPERFLEET-1582](https://redhat.atlassian.net/browse/HYPERFLEET-1582) — [SPIKE] Decide image delivery for CAPOCI and the OCI cloud controller manager (this spike).
- [HYPERFLEET-548](https://redhat.atlassian.net/browse/HYPERFLEET-548) — [HO] CAPOCI integration (epic).
- [HYPERFLEET-1547](https://redhat.atlassian.net/browse/HYPERFLEET-1547), [HYPERFLEET-1552](https://redhat.atlassian.net/browse/HYPERFLEET-1552) — the two blocked delivery stories.
- [HYPERFLEET-1546](https://redhat.atlassian.net/browse/HYPERFLEET-1546), [HYPERFLEET-1548](https://redhat.atlassian.net/browse/HYPERFLEET-1548) — CRDs and version pin, bound by the version rule above.
- [HYPERFLEET-1540](https://redhat.atlassian.net/browse/HYPERFLEET-1540), [HYPERFLEET-1592](https://redhat.atlassian.net/browse/HYPERFLEET-1592) — the OKE management cluster and the prototype run of 2026-08-25.
- [HYPERFLEET-1412](https://redhat.atlassian.net/browse/HYPERFLEET-1412), [HYPERFLEET-1411](https://redhat.atlassian.net/browse/HYPERFLEET-1411), [HYPERFLEET-1569](https://redhat.atlassian.net/browse/HYPERFLEET-1569) — disconnected `relatedImages` gate and bundle pinning.
- [ADR-0021](0021-oci-external-platform.md) — External platform for the guest; defers this decision. [ADR-0014](0014-konflux-build-and-release.md) — Konflux build and release, and the `app-interface-standard` policy.
- [openshift/hypershift#7305](https://github.com/openshift/hypershift/pull/7305) — the GCP CAPI provider, reference for Image A. [#7677](https://github.com/openshift/hypershift/pull/7677) and [#7731](https://github.com/openshift/hypershift/pull/7731) — the GCP cloud controller manager, reference for Image B.
- [oracle/cluster-api-provider-oci](https://github.com/oracle/cluster-api-provider-oci) and [oracle/oci-cloud-controller-manager](https://github.com/oracle/oci-cloud-controller-manager) — upstream sources, both Apache-2.0. Note the CCM image is published as `cloud-provider-oci` although the repository is `oci-cloud-controller-manager`.
