# Best practices

Lessons from running a small Kubernetes platform and its application repositories to one
baseline. Each entry is a problem that cost time once, and the rule that followed. Some of
them are enforced: the conformance checker fails a workload image without a digest
([`scripts/conformance`](../scripts/conformance/README.md)), and every tool this repository
installs in CI is checksum-verified.

Extracted from the private half's operating notes. Entries about the live authentication
setup, the node operating system and the platform's recovery limitations stay private.

## Table of Contents

- [Supply chain](#supply-chain)
  - [Pin container images by digest](#pin-container-images-by-digest)
  - [Use multi-arch digests for portable manifests](#use-multi-arch-digests-for-portable-manifests)
  - [Verify downloaded binaries with checksums](#verify-downloaded-binaries-with-checksums)
  - [The Helm install script needs openssl](#the-helm-install-script-needs-openssl)
- [Argo CD drift](#argo-cd-drift)
  - [Write CPU values the way the API server normalizes them](#write-cpu-values-the-way-the-api-server-normalizes-them)
  - [Ignore controller-managed fields](#ignore-controller-managed-fields)
  - [StatefulSet volumeClaimTemplates drift](#statefulset-volumeclaimtemplates-drift)
  - [Force a refresh for a stuck sync](#force-a-refresh-for-a-stuck-sync)
  - [Multi-source applications track one revision per source](#multi-source-applications-track-one-revision-per-source)
- [Observability](#observability)
  - [Collect pod logs from files, not through the API server](#collect-pod-logs-from-files-not-through-the-api-server)
- [Tekton](#tekton)
  - [Step resource limits are computeResources in the v1 API](#step-resource-limits-are-computeresources-in-the-v1-api)
  - [taskRunTemplate belongs to the PipelineRun](#taskruntemplate-belongs-to-the-pipelinerun)
  - [Cancel superseded pipeline runs](#cancel-superseded-pipeline-runs)
- [Helm](#helm)
  - [Check value paths against the chart](#check-value-paths-against-the-chart)
- [GitHub Packages](#github-packages)
  - [Actions and Packages share one storage bucket](#actions-and-packages-share-one-storage-bucket)
  - [A zero spending limit blocks at 100 percent](#a-zero-spending-limit-blocks-at-100-percent)
  - [The storage meter is cumulative](#the-storage-meter-is-cumulative)
  - [A cleanup token needs org-wide package visibility](#a-cleanup-token-needs-org-wide-package-visibility)
  - [Retention logs count candidates after the cut-off](#retention-logs-count-candidates-after-the-cut-off)
- [API design](#api-design)
  - [Bound every string field](#bound-every-string-field)
  - [Sanitize metric labels to control cardinality](#sanitize-metric-labels-to-control-cardinality)

## Supply chain

### Pin container images by digest

**Problem:** A tag, even a versioned one, can be moved to other content. For a privileged
workload that is a supply-chain attack path.

**Rule:** Pin every workload image by its SHA-256 digest, and let a dependency bot move the
digest.

```yaml
# Good -- immutable
image: alpine:<tag>@sha256:<64-hex-digest>

# Bad -- mutable
image: alpine:latest
image: alpine:<tag>
```

```bash
# Multi-arch manifest digest (preferred for portable manifests)
docker buildx imagetools inspect alpine:<tag>

# Per-architecture digests
docker manifest inspect alpine:<tag> | jq -r '.manifests[] | "\(.platform.architecture): \(.digest)"'
```

### Use multi-arch digests for portable manifests

**Problem:** An architecture-specific digest breaks a manifest that also runs on a laptop
cluster, which may be x86_64 or arm64.

**Rule:** Pin the multi-arch manifest digest and pick the architecture at run time where a
container downloads a binary:

```yaml
image: alpine:<tag>@sha256:<multi-arch-manifest-digest>
args:
  - |
    case "$(uname -m)" in
      x86_64|amd64) BINARY_ARCH="x86_64" ;;
      aarch64|arm64) BINARY_ARCH="arm64" ;;
      *) echo "Unsupported: $(uname -m)" && exit 1 ;;
    esac
```

An architecture-specific digest is fine where the target architecture is fixed.

### Verify downloaded binaries with checksums

**Problem:** A binary downloaded without verification trusts the network and the release
host.

**Rule:** Verify the SHA-256 before extracting, and fail on mismatch.

```bash
curl -fsSL -o /tmp/tool.tar.gz "${DOWNLOAD_URL}"
echo "${EXPECTED_SHA256}  /tmp/tool.tar.gz" | sha256sum -c -
tar -xzf /tmp/tool.tar.gz -C /target
```

Most projects publish `checksums.txt` or `SHA256SUMS` beside each release. Pin the expected
sum in the repository next to the version, and bump both together.

### The Helm install script needs openssl

**Problem:** The official `get-helm-3` script verifies its download with `openssl`. On a
minimal image such as Alpine it is missing, and the script stops with "In order to verify
checksum, openssl must first be installed."

**Rule:** Install `openssl` with the other dependencies:

```bash
apk add --no-cache curl bash openssl
```

## Argo CD drift

### Write CPU values the way the API server normalizes them

**Problem:** The API server stores `1000m` as `"1"`. Argo CD compares against Git and reports
the application OutOfSync forever.

**Rule:** Write whole cores as `"1"`, `"2"`, not `1000m`, `2000m`. Memory quantities do not
have this problem.

### Ignore controller-managed fields

Argo CD can report OutOfSync after a successful sync when something other than Argo CD owns a
field:

1. **A deprecated CRD field** (`preserveUnknownFields`) is stripped by the API server but
   present in the upstream manifest.
2. **A controller modifies the resource** after apply (Tekton's controllers do).
3. **The API server normalizes a value** differently from the manifest.

**Rule:** Ignore those fields globally in `argocd-cm`, by manager rather than by path:

```yaml
resource.customizations.ignoreDifferences.apiextensions.k8s.io_CustomResourceDefinition: |
  jsonPointers:
  - /spec/preserveUnknownFields

resource.customizations.ignoreDifferences.all: |
  managedFieldsManagers:
  - kube-controller-manager
  - tekton-pipelines-controller
  - tekton-triggers-controller
```

Or per application, with `RespectIgnoreDifferences` so the sync honours it too:

```yaml
spec:
  ignoreDifferences:
    - group: tekton.dev
      kind: '*'
      managedFieldsManagers:
        - tekton-pipelines-controller
  syncPolicy:
    syncOptions:
      - RespectIgnoreDifferences=true
```

### StatefulSet volumeClaimTemplates drift

The API server adds `apiVersion`, `kind`, `metadata.creationTimestamp: null` and `status` to
each entry of a StatefulSet's `volumeClaimTemplates`. A Helm chart does not render them.

```yaml
spec:
  ignoreDifferences:
    - group: apps
      kind: StatefulSet
      jsonPointers:
        - /spec/persistentVolumeClaimRetentionPolicy
        - /spec/volumeClaimTemplates/0/apiVersion
        - /spec/volumeClaimTemplates/0/kind
        - /spec/volumeClaimTemplates/0/status
        - /spec/volumeClaimTemplates/0/metadata/creationTimestamp
  syncPolicy:
    syncOptions:
      - RespectIgnoreDifferences=true
```

### Force a refresh for a stuck sync

```bash
# Hard refresh: re-fetch from Git
kubectl patch application <app> -n argocd --type merge \
  -p '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}'

# Still stale: restart the repo server to clear its cache
kubectl rollout restart deployment argocd-repo-server -n argocd
```

### Multi-source applications track one revision per source

With `sources:`, a chart version and a Git revision are tracked separately. Check both when a
sync does not pick up a change:

```yaml
spec:
  sources:
    - chart: <chart>
      repoURL: https://<chart-repository>
      targetRevision: <chart-version>
    - ref: values
      repoURL: https://github.com/<owner>/<repository>.git
      targetRevision: HEAD
```

```bash
kubectl get application <app> -n argocd \
  -o jsonpath='{.status.operationState.syncResult.revisions}'
```

## Observability

### Collect pod logs from files, not through the API server

**Problem:** Grafana Alloy's `loki.source.kubernetes` streams each pod's logs through the API
server (`pods/log`), one long-lived connection per pod. Across a cluster that became hundreds
of streams, spread unevenly: one API server carried most of them, used far more memory than
its peers and set off node memory-pressure alerts.

**Rule:** Read the files. Run the collector as a DaemonSet with `/var/log` mounted, use
`local.file_match` and `loki.source.file`, and keep only the pods on the collector's own node
with a `discovery.relabel` rule (`keep` where `__meta_kubernetes_pod_node_name` equals
`env("HOSTNAME")`). The `__path__` label is built from the pod's namespace, name, uid and
container. That is how every production log shipper works; the API-server method suits a quick
development setup without host access.

## Tekton

### Step resource limits are computeResources in the v1 API

**Problem:** In the Tekton v1 API a step's `resources:` field is silently ignored.

```yaml
steps:
  - name: build
    image: <maven-image>
    computeResources:        # correct in v1
      requests: { cpu: 500m, memory: 1Gi }
      limits: { cpu: "2", memory: 3Gi }
```

### taskRunTemplate belongs to the PipelineRun

**Problem:** `taskRunTemplate` (tolerations, affinity) is a `PipelineRun` field. On a
`Pipeline` it fails validation.

**Rule:** Put scheduling in the PipelineRun, or in the trigger template that creates it.

### Cancel superseded pipeline runs

**Problem:** Commits in quick succession start one pipeline run each. On small nodes,
concurrent Maven builds exhausted memory, took nodes NotReady and timed each other out.

**Rule:** Make the first task of every pipeline cancel its siblings:

```yaml
tasks:
  - name: cancel-superseded
    taskRef:
      name: cancel-superseded
    params:
      - name: pipeline-name
        value: $(context.pipeline.name)
      - name: current-pipelinerun
        value: $(context.pipelineRun.name)
```

The task lists the running PipelineRuns of the same pipeline, cancels older ones, and cancels
itself when a newer one exists. Only the newest commit builds. The run's service account needs
`patch` on `pipelineruns`.

## Helm

### Check value paths against the chart

**Problem:** A value under the wrong parent key is ignored without a warning.

```yaml
# Correct -- tolerations under controller
controller:
  type: daemonset
  tolerations:
    - key: node-role.kubernetes.io/control-plane
      operator: Exists
      effect: NoSchedule

# Wrong -- at the root, silently ignored
controller:
  type: daemonset
tolerations:
  - key: node-role.kubernetes.io/control-plane
```

**Rule:** Read the chart's own `values.yaml` (`helm show values <repo>/<chart>`) before adding
a key.

## GitHub Packages

### Actions and Packages share one storage bucket

On the Free plan the included storage is shared between Actions artifacts and package storage;
the billing page shows one "Actions and Packages storage" bar. Packages can be the small share.
Deleting images barely moves the bar when artifacts are the real consumer, so check both:

```bash
# Storage per SKU this period (gigabyte-hours)
gh api "organizations/<org>/settings/billing/usage?year=YYYY&month=M" \
  --jq '.usageItems|map(select(.sku|test("storage";"i")))|group_by(.sku)|.[]|"\(.[0].sku): \(map(.quantity)|add)"'

# Unexpired Actions artifacts of one repository (bytes)
gh api repos/<owner>/<repository>/actions/artifacts \
  --jq '[.artifacts[]|select(.expired==false).size_in_bytes]|add'
```

### A zero spending limit blocks at 100 percent

On the Free plan the default spending limit is zero. The moment usage passes the included tier,
GitHub blocks every package push and pull: `ImagePullBackOff` in the cluster, failed image
pushes in CI. A small limit lets the overage be billed instead of blocked; overage for a small
estate costs cents.

### The storage meter is cumulative

Storage is metered in gigabyte-hours over the billing period. A cleanup does not lower the
current period's bar; the saving shows in the next period.

### A cleanup token needs org-wide package visibility

A repository's `GITHUB_TOKEN` sees only packages linked to that repository. A retention job run
with it silently skips every unlinked organisation package and reports zero versions. Use a
token with organisation-wide `read:packages` and `delete:packages` (GitHub Packages accepts
classic tokens for this), or link each package to its repository. The
`snok/container-retention-policy` action checks for `delete:packages` even in dry-run mode.

### Retention logs count candidates after the cut-off

In `snok/container-retention-policy` logs, "Selected N package versions" counts versions after
the `cut-off` filter, not all fetched versions. Zero usually means everything is newer than the
cut-off, not a token problem.

## API design

### Bound every string field

**Problem:** An unbounded string field invites memory exhaustion from large payloads, storage
bloat, and unbounded metric cardinality if it ever becomes a label.

**Rule:** Put a size constraint on every string in a request model:

```java
public record WebVitalEntry(
    @NotBlank @Size(max = 64) String id,
    @Size(max = 32) String navigationType,
    @NotBlank @Size(max = 256) String route
) {}
```

| Field | Max | Why |
|---|---|---|
| Ids and tokens | 64 | A UUID is 36 characters |
| Route paths | 256 | A reasonable URL path |
| User agents | 512 | Some are long |
| Full URLs | 2048 | The common browser limit |
| Free text | 1024 and up | Depends on the use |

### Sanitize metric labels to control cardinality

**Problem:** Raw user input as a Prometheus label creates a new series per value, until
Prometheus runs out of memory.

**Rule:** Normalize before recording:

```java
private String sanitizeRoute(String route) {
    if (route == null || route.isBlank()) {
        return "unknown";
    }
    String sanitized = route.split("\\?")[0].split("#")[0];
    return sanitized
        .replaceAll("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", ":uuid")
        .replaceAll("/\\d+", "/:id");
}
```

The usual sources of cardinality: query strings, fragments, UUIDs and numeric ids in paths,
timestamps, session tokens.
