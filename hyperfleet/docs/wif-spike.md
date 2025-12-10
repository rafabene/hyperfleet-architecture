# Workload Identity Federation

## Problem statement

We need to provide a secure way to access customer's cloud infrastructure from several CLM components.

CLM components like "validator adapter task" and "DNS adapter task" need to query customer resources in their GCP project.

Note that this problem is different from having Hyperfleet components accessing Hyperfleet cloud resources, like Cloud DBs or broker topics/subscriptions. In the later case, the credentials are for a single GCP project owned and managed by Red Hat (or the provider of the solution, but in this case the GCP team from Red Hat, if operating as a 3p)

Challenges:
- Obtain customer credentials, or make customer to authorize an identity in our side with permissions
- Align with Hypershift Operator solution to provide a seamless experience for customers
- Ideally, design a solution that can be used in other cloud providers


## TL;DR; solution

- A customer has their infrastructure in `CUSTOMER_PROJECT_NAME` GCP project
- A customer creates a HostedCluster with name `CLUSTER_NAME`
- An adapter task runs wants to access customer infrastructure for the `CLUSTER_NAME` HostedCluster
  - It runs in a GKE cluster for the Regional setup
  - In a GCP project with 
     - GCP project name `HYPERFLEET_PROJECT_NAME`
     - GCP project number `HYPERFLEET_PROJECT_NUMBER`
  - In a namespace named `CLUSTER_NAME`
  - With a Kubernetes Service Account named `CLUSTER_NAME`
- For the example, let's say the adapter requires `pubsub.admin` permissions

The customer will have to run this gcloud command to grant permissions:

```
gcloud projects add-iam-policy-binding  projects/CUSTOMER_PROJECT_NAME \
  --role="roles/pubsub.admin" \
  --member="principal://iam.googleapis.com/projects/HYPERFLEET_PROJECT_NUMBER/locations/global/workloadIdentityPools/HYPERFLEET_PROJECT_NAME.svc.id.goog/subject/ns/CLUSTER_NAME/sa/CLUSTER_NAME" --condition=None 
```

**Question: Do the namespace and Kubernetes Service Account names be the same?**
No, this is TBD, we simplified this for the example

It is also good to have a namespace+ksa per customer, so in case a token is leaked, only that customer project is exposed

**Question: Does the kubernetes service account need to exist before the permissions are granted?**
No, it is not required

**Question: the name/Id of the Hyperfleet Regional cluster is not specified when granting permissions, why?**
All GKE clusters share the same Workload Identity Pool. Any cluster in `HYPERFLEET_PROJECT_NAME` with a workload running in a namespace+ksa named `CLUSTER_NAME` will have the granted permissions.

**Question: can access be restricted in a more fine grained way?**

First, we can use `add-iam-policy-binding` directly on resources. E.g. we can apply it on a specific existing topic.

We can also use the `--condition` parameter can be used to evaluate the permission.

e.g. limit access to topics that have a project tag "purpose" with value "hyperfleet"

```
gcloud projects add-iam-policy-binding  projects/CUSTOMER_PROJECT_NAME \
  --role="roles/pubsub.admin" \
  --member="principal://iam.googleapis.com/projects/HYPERFLEET_PROJECT_NUMBER/locations/global/workloadIdentityPools/HYPERFLEET_PROJECT_NAME.svc.id.goog/subject/ns/amarin/sa/gcloud-ksa"     --condition=^:^'expression=resource.matchTag("CUSTOMER_PROJECT_NAME/purpose", "hyperfleet"):title=hyperfleet-tag-condition:description=Grant access only for resources tagged as purpose hyperfleet'
``` 

note:
- GCP tags are different from labels)
- Specifying some conditions is tricky when using gcloud
  - tag names require to be prefixed with  `CUSTOMER_PROJECT_NAME/`
  - since the condition contains a `,` we need to specify another separator for condition properties using the syntax `^:^`


**Question: If Hyperfleet moves to another GCP project, does the customer need to re-grant permissions?**
Yes, since permissions are associated to a pool with HYPERFLEET_PROJECT_NAME




## Current GCP team approach 

The current approach by GCP team for Hypershift Operator in their PoC is a temporal solution sharing customer generated credentials. 

- Customer's use a Hypershift provided CLI tool to:
  - Create a private_key/public_key credentials pair
  - Upload the public key to the customer's Workload Identity Pool 
    - In the customer's GCP project that will host the worker nodes
  - Grant permissions in the customer's GCP project to certain kubernetes service accounts in the customer HostedCluster to be created
    - This step only requires the name of the customer_k8s_sa (to be created later)
    - As an example: "principal://iam.googleapis.com/projects/[HYPERFLEET_MANAGEMENT_CLUSTER_GCP_PROJECT_NUMBER]/locations/global/workloadIdentityPools/[HYPERFLEET_MANAGEMENT_CLUSTER_GCP_PROJECT_NAME].svc.id.goog/subject/system:serviceaccount:[NAMESPACE]:[K8S_SERVICE_ACCOUNT]"
  - Transfer the private_key to the Hypershift Operator leveraging CLM
    - CLM API accepts the private_key as part of the cluster.spec
    - CLM will transfer the private_key to HO using the "maestro adapter"
    - The HO will create a HostedCluster control plane that will use the provided private_key
    - Creates k8s_sa in the HostedCluster 
    - The HostedCluster will sign tokens for these k8s_sa using the provided private_key
  - The k8s_sa signed tokens have to be used by some HO component that live outside the HostedCluster
     - GCP team has developed a "minter" application that retrieves tokens from the HostedCluster
     - This is possible since HO has access to the kubeconfig for the HostedCluster

Pros:
- Each customer GCP project trust a different private_key/public_key, specific for the customer
  - No single Provider managed identity (or credential) has access to multiple customer projects
  - Still, access to all customer's infrastructure is possible since the ManagementCluster has access to all HostedClusters, so leaking those credentials would mean exposing all customers

Cons:
- Managing private_key/public_key lifecycle is challenging
  - Generating them 
  - Where to store them
  - Transfering them to HO through CLM
  - Rotating the credentials

### Suitability of this approach for CLM components

CLM can leverage the proposed mechanism but it comes with many challenges.
- Enable an API endpoint to accept the private_key (or have it in the `cluster.spec`)
- Store the private_key securely
- Retrieve the private_key from the adapters that require it
- Create a signed token per request

For Hypershift Operator, the component that stores the key and signs tokens is the HostedCluster

Pros:
- No changes to the existing UX for the customer. They will leverage the CLI to drive the process

## Leverage Regional cluster Workload Identity Pool

Instead of managing manually the private_key/public_key we can make use of the Google-managed encryption for GKE.

A GKE cluster will be associated with a Workload Identity Pool which will sign tokens for identities that the customer can enable as an OIDC provider for their projects. This all happens through configuration in GCP and no private keys have to be exchanged between the customer and Hyperfleet

- GKE Regional Cluster has an associated Workload Identity Pool
- The pool will sign tokens for the k8s Service Accounts in the GKE cluster
- The customer configures grants permissions to a k8s service account running of the GKE Regional Cluster
- A workload in the GKE Regional cluster running as the k8s Service Account can access customer's cloud resources

As an example: 
- For a customer project named CUSTOMER_PROJECT, 
- The role `pubsub.admin` will be granted
- To a k8s service account named `hyperfleet-sa`
  - In the namespace `hyperfleet`
  - In the GCP Project `hcm-hyperfleet` (with project number 12341234)

```
gcloud projects add-iam-policy-binding  projects/CUSTOMER_PROJECT \
  --role="roles/pubsub.admin" \
  --member="principal://iam.googleapis.com/projects/12341234/locations/global/workloadIdentityPools/hcm-hyperfleet.svc.id.goog/subject/ns/hyperfleet/sa/hyperfleet-sa" --condition=None

```

This command gives direct permission to the k8s service account, without requiring:
- An intermediate GCP Service Account
- No need for a customer OIDC Provider nor Workload Identity Pool
- No need to annotate anything in the k8s Service Account, nor the namespace


#### caveat: Workload Identity sameness

GCP documentation: https://docs.cloud.google.com/kubernetes-engine/docs/concepts/workload-identity#identity_sameness

There is a minor caveat with the GCP implementation of Workload Identity for GKE, where permissions are granted to a k8s service account in a namespace **regardless of the cluster. This means that the same combination of namespace+serviceaccount will have the same customer permissions in all GKE clusters created in a GCP project.

Some explanation:

All GKE cluster in a GCP project with Workload Identity enabled use the same Workload Identity Pool named `PROJECT_ID.svc.id.goog`. This is a Google managed Identity Pool that is not visible in the GCP console.

For example, for the GCP project `hcm-hyperfleet` the identity pool is `hcm-hyperfleet.svc.id.goog` and can be checked with the command:

```
gcloud iam workload-identity-pools describe hcm-hyperfleet.svc.id.goog  --location=global --project hcm-hyperfleet

name: projects/275239757837/locations/global/workloadIdentityPools/hcm-hyperfleet.svc.id.goog
state: ACTIVE
```

But not if tried to list it as other Workload Identity pools that are usually used for external identity federation like AWS or Azure

```
gcloud iam workload-identity-pools list  --location=global --project hcm-hyperfleet

Listed 0 items.
```


For the cluster hyperfleet-dev, the JWT configuration can be found at:

https://container.googleapis.com/v1/projects/hcm-hyperfleet/locations/us-central1-a/clusters/hyperfleet-dev/.well-known/openid-configuration



References:
- Workload Identity from GKE: https://docs.cloud.google.com/kubernetes-engine/docs/how-to/workload-identity#authenticating_to
- Workload Identity Sameness: https://medium.com/google-cloud/solving-the-workload-identity-sameness-with-iam-conditions-c02eba2b0c13




