# Zesty Kompass on EKS — Deployment Guide

Terraform-managed EKS cluster in account `695214758399` (`eu-west-1`), with Zesty Kompass
installed via Helm using the account's existing `values.yaml`. Code lives in
[`../terraform`](../terraform).

## Architecture

```
Existing VPC (vpc-03f7d8969ed41919f, "my-eks-vpc-stack-VPC")
  ├─ 2 public subnets (eu-west-1a/b)   — control-plane ENIs, load balancers
  └─ 2 private subnets (eu-west-1a/b)  — EKS managed node group (t3.medium x2)
       │
       ├─ EKS cluster "zesty-kompass" (Kubernetes 1.35)
       │    addons: vpc-cni, kube-proxy, eks-pod-identity-agent (before_compute),
       │             coredns, aws-ebs-csi-driver
       │    StorageClass "gp2" → ebs.csi.aws.com (Pod Identity for IAM perms)
       │
       └─ helm_release "kompass" (chart: zesty-co/kompass, pinned to 0.3.7)
            values = /home/edrio/values.yaml, as-is
```

Chart is pinned to `0.3.7` (see Troubleshooting) rather than left to float to latest.

We reused the VPC (`my-eks-vpc-stack-VPC`) rather than the account's plain default VPC — it's a
CloudFormation-provisioned "Amazon EKS Sample VPC" already shared by other demo clusters in this
account, with proper public/private subnets, NAT gateways, and EKS subnet tags already in place.
No new subnets, NAT gateways, or route tables were created.

**No Zesty account registration is provisioned here.** Account `695214758399` is already
registered with Zesty — `values.yaml`'s `assumeRole.roleArn` / `zestyExternalID` / `orgID` / API
keys are for that existing registration, and its `clusterName` (`"zesty-kompass"`) already
matches this cluster. Terraform just installs the Kompass Helm chart into the new cluster,
joining it to the account that already exists, using that file directly as Helm values. (An
earlier version of this config used the `terraform-aws-zesty-account` module to provision a
*new* account registration — that's the right tool when onboarding a not-yet-registered account,
but it 400'd here because this one already exists. See Troubleshooting.)

## Prerequisites

- Terraform ≥ 1.5 (deployed with v1.9.8)
- `aws`, `kubectl`, `helm` CLIs
- AWS credentials for account `695214758399` with admin access (profile
  `695214758399_AdministratorAccess` — SSO-based, **expires and needs periodic re-auth**, see
  Troubleshooting)
- `/home/edrio/values.yaml` present (Kompass Helm values for the already-registered account)

No Zesty API token is needed for Terraform itself — the `zesty` provider isn't used by this
config. `values.yaml` carries whatever Zesty API keys the Kompass application itself needs at
runtime.

## Deploying

```bash
cd terraform
terraform init
terraform plan -out=tfplan.out
terraform apply "tfplan.out"
```

Apply takes ~15–20 minutes, mostly EKS control plane + node group provisioning.

## Verification

```bash
aws eks update-kubeconfig --name zesty-kompass --region eu-west-1 \
  --profile 695214758399_AdministratorAccess

kubectl get nodes -o wide          # both nodes should reach Ready
kubectl get pods -A                # coredns, kube-proxy, aws-node (vpc-cni), ebs-csi,
                                    # eks-pod-identity-agent, and kompass-* pods all Running

helm list -n zesty-system          # "kompass" release, status deployed
kubectl get pods -n zesty-system | grep pre-upgrade-apply-crds
                                    # this hook Job is the one that 403'd in the original
                                    # (pre-Terraform) attempt against the wrong AWS account -
                                    # confirm it completes here

kubectl get pvc -n zesty-system    # kompass-insights-db-pvc and storage-kompass-grafana-0
                                    # should both be Bound on the gp2 StorageClass
```

## Teardown

```bash
terraform destroy -target=helm_release.kompass
terraform destroy
```

Note the NAT gateway and VPC in use are **not** ours to destroy — we only referenced existing
subnets, nothing VPC-level was created here.

## Troubleshooting

Issues actually hit while building this out, in case they recur:

**`AWS SSO session token expired` mid-apply/plan.** Hit repeatedly enough during this deployment
that it's worth setting up properly rather than re-authenticating by hand each time. The profile
was originally just static short-lived STS credentials hand-pasted into `~/.aws/credentials`
(likely copied from the access portal's "Command line or programmatic access" popup) - nothing
about that can auto-refresh. Fixed by configuring it as a real AWS SSO CLI profile instead, in
`~/.aws/config`:

```ini
[sso-session zesty]
sso_start_url = https://d-936708e699.awsapps.com/start
sso_region = eu-west-1
sso_registration_scopes = sso:account:access

[profile 695214758399_AdministratorAccess]
sso_session = zesty
sso_account_id = 695214758399
sso_role_name = AdministratorAccess
region = eu-west-1
```

With this in place, `aws sso login --profile 695214758399_AdministratorAccess` (one command, one
browser click) refreshes the whole SSO session, and both the AWS CLI and Terraform's AWS
provider auto-refresh short-lived role credentials transparently for that session's full
lifetime - no more manual credential copy-pasting in between. **Important:** if a static
`[695214758399_AdministratorAccess]` section still exists in `~/.aws/credentials`, remove it -
its presence took precedence over the SSO config for at least one credential-resolution path
(Terraform's AWS provider still hit `ExpiredToken` even after a successful `aws sso login`/CLI
check, until that stale section was deleted). Ask whoever manages IAM Identity Center whether the
`AdministratorAccess` permission set's session duration can be extended (up to 12h) to reduce how
often even this one-command refresh is needed.

**`~/.aws/credentials` fails to parse** (`Unable to parse config file`). The AWS credentials INI
format only recognizes `#` or `;` for comments — a stray `//`-style comment (e.g. from
hand-editing a duplicate profile block) breaks the parser for the *entire* file, not just that
line. Check for and remove any non-`#`/`;` comment syntax.

**EKS managed node group `CREATE_FAILED` / `NodeCreationFailure: Unhealthy nodes`, with zero
pods anywhere in the cluster (`kubectl get pods -A` → `No resources found`).** Root cause: the
`terraform-aws-modules/eks/aws` module installs addons *after* the node group is healthy by
default. `vpc-cni` is the CNI plugin nodes need to report `Ready` at all — so with the default
ordering, the module waits on nodes that can never become `Ready` without an addon it hasn't
installed yet, and the node group times out after ~20–30 min having never had any addon created
(`aws eks describe-addon` returns `ResourceNotFoundException` for all of them, not "created but
unhealthy"). Confirmed via the EKS control-plane authenticator logs that nodes *did* successfully
authenticate (`system:node:...` in group `system:nodes`) — the failure is downstream of auth,
purely a missing-CNI networking issue. Fixed by setting `before_compute = true` on `vpc-cni`,
`kube-proxy`, and `eks-pod-identity-agent` in the `addons` block, so they install before the
module waits on node health.

**A `-replace`'d node group leaves the old one running.** The `eks_managed_node_group` submodule
uses `create_before_destroy`. If the apply errors out *after* the new node group is created but
*before* Terraform reaches the old one's destroy step (e.g. a later resource in the same apply
fails), the old node group is silently orphaned — no longer in Terraform state at all, but still
running and billing in AWS. Check `aws eks list-nodegroups` for more than the expected count
after any apply that touched the node group, and `aws eks delete-nodegroup` any orphans directly.
This happened here: a later `aws-ebs-csi-driver` addon timeout (next item) left an old
`CREATE_FAILED` node group's 2 EC2 instances running for hours after `-replace` had already
successfully created its replacement.

**`aws-ebs-csi-driver` (or any addon needing IAM) stuck `CREATING` for the full 20-minute
timeout, `ebs-csi-controller` pods in `CrashLoopBackOff`.** The same class of bug as the
`vpc-cni` issue above, one level more subtle: a custom `aws_eks_pod_identity_association` +
supporting IAM role/policy for the addon had `depends_on = [module.eks]`. That forces the
association to wait for *the entire module* - including the very addon it's supposed to
unblock - so the addon's pods start with no IAM permissions, crash-loop, and the addon never
reports `ACTIVE`. Fixed by dropping the module-wide `depends_on` and relying on the existing
`cluster_name = module.eks.cluster_name` attribute reference for ordering (which only waits on
the cluster itself, not unrelated addons). Applied the same fix to `kubernetes_storage_class.gp2`
and the (now-removed) Kompass Helm module call, which had the identical over-broad dependency.
A node group or addon left in a terminal failed/tainted state from a prior apply needs explicit
forced replacement (`terraform apply -replace='...'`) or shows up as `is tainted, so must be
replaced` in the next plan - Terraform won't retry a failed create on its own.

**`Error: Unable to Validate Zesty API Client` / `status: 403, body: {"message":"Forbidden"}`
(from an earlier version of this config that used the `zesty` provider to register a new
account).** In order of what was actually hit chasing this down:
1. Using the wrong key (e.g. `values.yaml`'s `cxLogging.apiKey`, a telemetry key, not an account
   API token).
2. A single transposed digit in an org ID passed around out-of-band.
3. A response with AWS API Gateway headers (`x-amzn-errortype: ForbiddenException`) rather than
   an app-level error can mean the key isn't attached to the Usage Plan on the specific API
   Gateway backing the domain being hit.
4. `Error creating account ... status: 400, body: {"error":"Invalid request"}`, including on a
   bodyless `GET /accounts` (ruling out a payload issue) — turned out the account was already
   registered; no new registration was needed at all. See the Architecture note above.

Do **not** set `ZESTY_HOST` / override `host` in a `provider "zesty"` block if you do end up
needing that provider again for a genuinely new account - the default
(`api.zesty.co/kompass-platform`) is correct for prod. An alternate host shown in the
`terraform-aws-zesty-account` module's own examples, `kompass-onboarding.zesty.co`, resolves to
a private IP and isn't reachable over the public internet.

**`EntityAlreadyExists: Role with name ZestyIamRole already exists.`** (also from the
now-removed account-registration path) — collided with a role from an earlier onboarding attempt
already present in this account. No longer relevant since that module isn't used, but worth
knowing this account already carries a role by that exact name if the account-registration path
is ever revisited.

**`Error: Unauthorized` creating `kubernetes_storage_class.gp2` on an otherwise-healthy fresh
cluster** (addons all created fine, `null_resource.delete_default_gp2_storageclass`'s `kubectl`
call succeeded, but the `kubernetes`/`helm` *providers'* own bearer token got rejected). A
brand-new access entry (from `enable_cluster_creator_admin_permissions`) can take a short while
to propagate to the API server's authorization layer - `kubectl` via a separately-invoked ambient
CLI session isn't affected, but Terraform's own generated token (`data.aws_eks_cluster_auth` in
`providers.tf`) hit this window directly once, and a plain retry a few minutes later succeeded
with no config changes. Fixed with a `time_sleep` (30s) between the cluster/pod-identity setup
and the first resource that uses the `kubernetes`/`helm` providers, rather than relying on a
manual retry going forward.

**Kompass pods erroring `couldn't find key ORG_ID in Secret zesty-system/kompass-insights-secret`
(`kompass-pod-placement` `CrashLoopBackOff`, `kompass-rightsizing-action-taker`/
`recommendations-maker` `CreateContainerConfigError`).** Installing the latest chart (`0.3.10`,
unpinned) against this `values.yaml` left several components unable to read expected secret
keys. The original (pre-Terraform) onboarding attempt documented in `zesty-ecr-access-report.md`
used `kompass/kompass v0.3.7` - several minor versions back - and the values schema had
apparently shifted since. Fixed by pinning `version = "0.3.7"` on the `helm_release` resource.
Worth rechecking against a newer chart version deliberately at some point, with the values
migrated properly, rather than staying pinned indefinitely.

**Grafana PVC stuck `Pending`: `no persistent volumes available for this claim and no storage
class is set`, even though `values.yaml` sets a storage class for it.** Two compounding issues,
confirmed by pulling the chart source (`helm pull kompass/kompass --version 0.3.7 --untar`):
1. `values.yaml` sets `grafana.persistentVolume.storageClassName`, but the bundled Grafana
   subchart's actual field is `grafana.persistence.storageClassName` - `persistentVolume` isn't
   a key that chart recognizes, so Helm silently drops it and Grafana falls back to its own
   default (empty `storageClassName`). Note `victoriaMetrics.server.persistentVolume.storageClassName`
   *is* correct as written - it's a different bundled chart with a different schema, so the same
   `persistentVolume` key name is right in one place and wrong in the other.
2. The chart's own default values.yaml defines `global.storageClassName: &storageClassName ~`
   and references it via `*storageClassName` anchor in four places (including Grafana's
   persistence block), apparently intending a single global override to propagate everywhere.
   YAML anchors only resolve within a single parsed document, though - they don't survive across
   Helm's merge of the chart's default values with an externally supplied `-f values.yaml`. So
   setting `global.storageClassName` alone was never going to fix this regardless of the
   `persistentVolume`/`persistence` naming issue; each component needs its storage class set
   directly.
3. Even after correcting the values, Helm couldn't apply the fix to the *already-created*
   `StatefulSet` - `volumeClaimTemplates` is an immutable field in Kubernetes, so the upgrade
   silently failed on that one resource while `terraform apply` still reported success (the
   `helm_release` resource has `wait = false`, so Terraform doesn't catch async failures; check
   `helm status kompass -n zesty-system` directly if something looks off despite a clean
   `apply`). Required deleting the StatefulSet *and* its PVC (`kubectl delete statefulset
   kompass-grafana pvc storage-kompass-grafana-0 -n zesty-system`) before the next
   `terraform apply` so Helm could recreate both from scratch with the corrected template.

**`kompass-victoria-metrics-0` stuck `Pending`: `Insufficient memory`.** Capacity, not a
config bug - the 2x `t3.medium` nodes don't have enough free memory once everything else is
scheduled. Left unresolved: the VictoriaMetrics single-server pod (the actual metrics storage
backend behind `victoriaMetricsAuth`/`useSingle: true`) never starts, so `kompass-victoria-metrics-agent`
(which *is* running and scraping) has nowhere to remote-write to - metrics get dropped, not
queued indefinitely. Downstream effects: Grafana dashboards querying this datasource show no
data; any Kompass component that bases recommendations on historical usage (rightsizing,
pod-placement scoring) has no metrics history to work from, so those features are effectively
non-functional even though their pods report `Running`. It won't cascade into other components
crashing or destabilize the cluster - a `Pending` pod just sits unscheduled - and it won't
self-resolve without more capacity or lower resource requests. Fix is either `node_instance_type`
/ `node_desired_size`/`node_max_size` bumps in `variables.tf`, or reducing VictoriaMetrics'
resource requests in `values.yaml`.

**Original (pre-Terraform) failure this whole effort was redoing:** a manual/prior Kompass
install into a *different* AWS account (`161479556310`) hit a `403 Forbidden` pulling
`kompass-pre-upgrade-apply-crds`'s image from Zesty's private ECR, because that account wasn't
allow-listed against the `values.yaml` in use (which was scoped to `695214758399`). Deploying
into `695214758399` — the account `values.yaml` actually matches — avoids this.
