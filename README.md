# peithos-kubernetes

The Helm chart and Dockerfile that run [peithos.ai](https://peithos.ai) on Kubernetes:
one long running web service and one scheduled worker, on a three node cluster.

This is not a tutorial cluster with an nginx pod in it. It runs the same Next.js
application that serves peithos.ai, from the same repository, with the same scheduled
job that reconciles orders in production.

**The part worth reading is [Verified, not assumed](#verified-not-assumed).** Every
claim here was measured on the running cluster, and the first measurement found a real
defect: a rolling update dropped **3 of 502 requests**. Tracing that to the race between
SIGTERM and endpoint withdrawal, fixing it, and remeasuring at **0 of 800** is most of
what this repository is for.

**About this repository.** The application itself lives in a private repo, so what is
here is the deployment: the chart, the multi stage Dockerfile, and the health endpoint
the probes call. The chart works against any Next.js application that serves
`/api/health` and copies its `scripts/` directory into the runtime image.

## Why it exists

Production today is Vercel for the web app and GitHub Actions for the scheduled
work. That is a good setup and it is not being replaced. This is the same two
workloads expressed the way a company running its own cluster would express
them, because the shape of the problem is identical: one long running service
that has to stay up through a deploy, and one job on a schedule that must not
run twice over the same rows.

## What is in it

| Object | Why |
|---|---|
| Deployment | 2 replicas, rolling update at `maxUnavailable: 0`, pod anti-affinity across nodes |
| Service | ClusterIP, the stable name the CronJob and the Ingress both talk to |
| Ingress | Traefik, host routed |
| ConfigMap | Non-secret config, hashed into the pod template so a change rolls the pods |
| Secret | Placeholders only. See "Secrets" below |
| HorizontalPodAutoscaler | CPU at 70% of request, 2 to 6 pods, 5 minute scale-down window |
| PodDisruptionBudget | A node drain cannot take both replicas at once |
| CronJob | Every 5 minutes, `concurrencyPolicy: Forbid`, keeps more failures than successes |

## The decisions worth defending

**Three probes, not one.** `startupProbe` gives a slow first boot up to sixty
seconds without the liveness probe killing it halfway. `readinessProbe` decides
whether a pod receives traffic. `livenessProbe` decides whether it is dead and
needs replacing. Collapsing these into one probe is the most common way to build
a service that restarts itself under load instead of shedding it.

**The health endpoint does not check the database.** `/api/health` returns
without touching Supabase, Stripe or fal. A readiness probe that depends on a
third party takes your own pods out of rotation when that third party has a bad
minute. That converts someone else's brief outage into your total outage.

**`replicas` is omitted when the HPA is on.** If both the Deployment and the
HPA own the replica count, every `helm upgrade` stamps the count back to the
chart value and undoes whatever the autoscaler had decided.

**Config changes roll the pods.** Kubernetes does not restart a pod when the
ConfigMap or Secret it read at startup changes. The pod template annotates a
`sha256sum` of both, so editing config produces a new pod spec and a normal
rolling update, instead of a change that appears to apply and silently does not.

**`concurrencyPolicy: Forbid` on the CronJob.** The real job reconciles orders.
If a run is slow and the next fire starts anyway, two processes work the same
rows. Forbid skips the fire instead.

**One image, two workloads.** The Dockerfile copies `scripts/` into the runtime
stage, so the web Deployment and the CronJob run the same artifact with
different entrypoints. One build, one tag to roll back, no drift between what
serves traffic and what runs the batch.

**Never `:latest`.** A tag you cannot pin is a deploy you cannot roll back.

## Secrets

The values in [`chart/values.yaml`](chart/values.yaml) under `secrets:` are placeholders and are not
real. No live credential is in this chart, this repository, or the image.

Kubernetes Secrets are base64, which is encoding, not encryption. Anyone who can
read the object can read the value. The template exists to show the wiring. In a
real cluster the values arrive from a secret manager, either the External
Secrets Operator pulling from Azure Key Vault, or Sealed Secrets so the
encrypted form is safe to commit. Both land in exactly the Secret this chart
already defines, and nothing else in the chart changes.

## Running it

```bash
# 1. A local cluster: one control plane, two agents, port 8080 to the LB
k3d cluster create peithos --agents 2 -p "8080:80@loadbalancer"

# 2. Build and load the image
docker build -f Dockerfile -t peithos-web:0.1.1 /path/to/the/app
k3d image import peithos-web:0.1.1 -c peithos

# 3. Install
helm install peithos ./chart --namespace peithos --create-namespace --wait

# 4. Prove it serves traffic
curl -H 'Host: peithos.localhost' http://localhost:8080/api/health

# 5. Run the scheduled job now instead of waiting for the next fire
kubectl create job -n peithos --from=cronjob/peithos-worker manual-1
kubectl logs -n peithos job/manual-1
```

Uninstall with `helm uninstall peithos -n peithos`, or delete the whole cluster
with `k3d cluster delete peithos`.

## Verified, not assumed

Every claim above was measured on the running cluster, because a manifest that
applies cleanly is not a service that works.

**Zero-downtime deploys.** A poller hit `/api/health` through the ingress in a
tight loop while a rolling update ran underneath it.

| | Requests | Failed |
|---|---|---|
| First attempt | 502 | **3** (one 502, two connection failures) |
| After the fix | 800 | **0** |

The first result was the interesting one. A pod being deleted gets SIGTERM at
the same moment its endpoint is removed from the Service, and neither waits for
the other. The ingress controller learns about the removal a moment later, so
for that moment it is still sending requests to a pod that has begun shutting
down. The fix is a `preStop` hook holding the container open for five seconds
so the removal propagates first, with the pod still serving normally throughout.

**The rest, each checked directly:**

- Both replicas landed on different nodes, as the anti-affinity asks.
- The CronJob resolved the web Service by cluster DNS and got a real 200 back,
  with no address hardcoded anywhere.
- The HPA read live CPU off metrics-server, reporting 12% against its 70% target.
- Four Helm upgrades ran clean, and a ConfigMap-only change rolled the pods,
  which is what the checksum annotation is for.
- The home page renders through the ingress at 200, 48KB.

## What is deliberately not here

No service mesh, no GitOps controller, no cert-manager. Each one is a real
answer to a real problem this workload does not have yet, and adding them to say
they are present would make the chart harder to read without making the
service better.
