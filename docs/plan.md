# MLOps Homelab — Stage 1 (Local) & Stage 2 (EKS) Plan

> **Two stages:** kind on Docker Desktop (~10 weeks) → ephemeral EKS with NVIDIA GPUs (~6 weeks). Budget: 6–10 hours/week.

---

## Overview

Build a production-shaped, self-hosted LLM serving platform in two stages: develop everything on a local kind cluster (Stage 1, ~10 weeks), then promote the same Git repo to an ephemeral EKS cluster with NVIDIA GPUs (Stage 2, ~6 weeks).

### Goals

- Run the full lifecycle of a model: data → training → model registry → eval gate → serving → gateway → observability.
- Learn GPU serving and GPU training infrastructure on real NVIDIA hardware: GPU scheduling, vLLM tuning, autoscaling, cold starts, cost per token, job queueing, checkpoint/resume.
- End with a portfolio repo plus write-ups that hold up in big-tech MLOps/LLMOps interviews.

### Principles

- Industry-standard components only. Everything is declared in Git and deployed by ArgoCD.
- Local first: a component moves to EKS only after it works on kind and needs something kind cannot give.
- Environment differences live only in Kustomize overlays (`local` vs `eks`).
- Personal laptop, personal accounts. No employer code, data or credentials.

**Out of scope:** pretraining or full fine-tuning of large models, multi-GPU tensor parallelism for serving, 24/7 public uptime.

---

## Target Architecture

```
Git repo → GitHub Actions → ArgoCD
                                └── Cluster (kind / EKS)
                                      ├── search-api
                                      │     └── LiteLLM gateway
                                      │           └── Model servers
                                      │                 Stage 1: llama.cpp CPU + Mac Metal
                                      │                 Stage 2: vLLM on spot GPU nodes
                                      ├── Prometheus + Grafana (scrapes gateway metrics)
                                      └── MLflow registry → Object store (MinIO / S3)
                                                              └── weights at startup → model servers
```

CI runs the eval gate and moves the MLflow alias; ArgoCD then rolls the new version out. Moving to Stage 2 swaps MinIO for S3 and adds vLLM on GPU nodes; the gateway, registry and monitoring stay the same. Training jobs (1.8, 2.6) run in the same cluster and feed the same registry: Argo Workflows locally, Kueue-scheduled GPU jobs on EKS.

---

## Repo Layout

One repo drives both stages: ArgoCD app-of-apps for the platform, and Kustomize base + overlays per environment.

```
mlops-lab/
├── infra/
│   ├── kind/                 # kind-config.yaml: 1 control plane + 2 workers
│   └── terraform/eks/        # VPC, EKS, node groups, Karpenter, IRSA, ECR, S3
├── platform/                 # cluster add-ons as ArgoCD Applications
│   ├── argocd/
│   ├── ingress-nginx/        # local; AWS LB Controller on EKS
│   ├── minio/                # local only (S3 on EKS)
│   ├── postgres/
│   ├── mlflow/
│   ├── kube-prometheus-stack/
│   ├── keda/
│   ├── argo-workflows/
│   ├── kueue/                # eks only
│   └── gpu-operator/         # eks only
├── serving/
│   ├── llama-cpp/            # base + overlays/local
│   ├── vllm/                 # base + overlays/eks
│   └── litellm/              # base + overlays/{local,eks}
├── apps/search-api/          # FastAPI app that calls the gateway
├── training/                 # data prep, fine-tune scripts, Argo/Kueue job specs
├── evals/                    # golden sets, eval runner, promotion script
├── loadtest/                 # k6 scripts
├── scripts/                  # register_model.py, eks-down.sh
├── .github/workflows/        # lint, build, push, eval gate
└── docs/                     # ADRs, milestone write-ups, incident notes
```

---

## Stage 1 — Local (kind on Docker Desktop)

Stage 1 builds the whole platform on the MacBook at zero cloud cost. In-cluster serving is CPU-only (containers on macOS cannot use Metal), with an optional Metal-accelerated backend running natively on the host.

### Prerequisites

- Docker Desktop with at least 8 GB RAM and 6 CPUs allocated (Settings → Resources); more if the Mac has it.
- CLIs: `kind`, `kubectl`, `helm`, `kustomize`, `argocd`, `k9s`, `mc` (MinIO client), `k6`, `terraform`, `awscli`.
- GitHub repo + Actions; GHCR for container images in Stage 1.
- Hugging Face account for model downloads.
- **Open question:** Mac chip and RAM — this decides the model sizes below.

---

### 1.1 Cluster + GitOps (week 1)

- kind cluster: 1 control plane, 2 workers. Label workers with fake zones (`topology.kubernetes.io/zone=a|b`).
- Install ArgoCD with Helm, then an app-of-apps pointing at `platform/`.
- Add ingress-nginx and metrics-server.
- **Done when:** `kind delete cluster` → one bootstrap script + ArgoCD sync brings everything back in under 15 minutes.

### 1.2 Storage + model registry (week 2)

- MinIO with buckets `models/` and `mlflow/`; Postgres as the MLflow backend; MLflow tracking server with MinIO as its S3 artifact store.
- `scripts/register_model.py`: download a GGUF from Hugging Face → upload to MinIO → register in MLflow with tags (source, quantization, sha256) and aliases `staging` / `production`.
- **Done when:** two versions of one model (e.g. Qwen2.5-1.5B-Instruct Q4_K_M and Q8_0) are registered with full lineage in the MLflow UI.

### 1.3 In-cluster LLM serving (week 3)

- llama.cpp server Deployment. An initContainer resolves the MLflow alias and pulls the weights from MinIO into a volume.
- Requests/limits, a startupProbe that covers model load, and a readinessProbe on `/health`.
- Service + Ingress exposing the OpenAI-compatible `/v1/chat/completions`.
- **Done when:** a rolling update between model versions runs with zero failed requests while k6 sends traffic.

### 1.4 Host Metal backend (week 3, optional)

- llama.cpp server running natively on macOS with Metal, serving a larger model (7–8B if RAM allows).
- Selector-less Service + EndpointSlice pointing at the host, or an ExternalName to `host.docker.internal`.
- **Done when:** a pod in the cluster reaches the host model through Service DNS.

### 1.5 Gateway + app (week 4)

- LiteLLM proxy with two backends (`cpu-small` in-cluster, `metal-large` on the host): virtual keys, per-key rate limits, fallback routing, token and spend logging to Postgres.
- `apps/search-api` (FastAPI) calls the gateway. CI builds and pushes the image to GHCR; ArgoCD deploys on a tag bump.
- **Done when:** stopping the host backend triggers automatic fallback, visible in gateway logs and metrics.

### 1.6 Observability (week 5)

- kube-prometheus-stack. Scrape llama.cpp `/metrics` (`--metrics` flag), LiteLLM's Prometheus metrics and the app's own metrics.
- Grafana dashboard: requests/sec, p50/p95/p99 latency, TTFT, tokens/sec, error rate, pod CPU/memory, tokens per API key.
- SLOs, e.g. p95 TTFT under 2 s at 2 concurrent users; Alertmanager rules for error rate and pod restarts.
- Optional: Loki + Promtail for logs.
- **Done when:** a k6 run shows clearly on the dashboard and an induced failure fires an alert.

### 1.7 Eval gate + load testing (weeks 6–7)

- `evals/`: a golden set of 50–200 prompts with references. Metrics: task accuracy or an LLM-as-judge rubric, format validity, latency, tokens per answer.
- Promotion script compares `staging` vs `production`: promote only if quality ≥ production minus a set tolerance and p95 latency is no more than 10% worse. Results are logged to MLflow.
- GitHub Actions (self-hosted runner on the Mac, or manual dispatch) runs evals → moves the MLflow alias → commits the new version to the `local` overlay → ArgoCD rolls it out.
- k6 ramp from 1 to N concurrent users; record TTFT and throughput curves per model and quantization in `docs/`.
- Optional: Argo Rollouts canary (10% → 50% → 100%) with automatic rollback on error-rate analysis.
- **Done when:** a deliberately worse model (e.g. a Q2 quant) is rejected automatically, and a better one ships with no manual `kubectl`.

### 1.8 Training pipeline (weeks 8–9)

- Pick one small fine-tuning task: an embedding model (e.g. bge-small) on a domain retrieval set, or a LoRA on a 0.5–1.5B instruct model.
- Version the dataset with DVC (MinIO remote); validate it with Pandera or Great Expectations so a bad batch fails the run.
- Build the pipeline in **Argo Workflows** (or Kubeflow Pipelines): data prep → validation → train → eval → register in MLflow as `staging`. Each step is its own container image built by CI.
- In-cluster steps run on CPU. Heavier runs can go natively on the Mac (MLX or PyTorch MPS), but still log to the in-cluster MLflow and push artifacts to MinIO.
- Log params, metrics, data version and git SHA for every run; save checkpoints so a killed run can resume.
- The registered model goes straight into the 1.7 eval gate, then rollout.
- **Done when:** one command (or a Git push) runs data → train → eval → register, and the resulting model reaches production through the gate with no manual steps.

### Week 10: buffer + write-up

Catch up, then write the Stage 1 README, architecture notes and a short post-mortem of anything that broke.

---

## Stage 1 Exit Criteria

Stage 2 starts only when every box below is ticked.

- [ ] Cluster rebuilds from Git in under 15 minutes with no manual steps
- [ ] Two or more model versions in MLflow, weights in MinIO, served by alias
- [ ] Zero-downtime model rollout verified under k6 load
- [ ] Gateway routes, rate-limits and falls back across two backends
- [ ] Grafana dashboard with latency, TTFT, tokens/sec and errors; at least one working alert
- [ ] Eval gate rejects a worse model and promotes a better one end to end
- [ ] TTFT/throughput curves and a Stage 1 write-up committed to `docs/`
- [ ] Training pipeline runs data → train → eval → register from one trigger, and its model ships through the gate

---

## Stage 2 — EKS with NVIDIA GPUs (ephemeral)

Stage 2 promotes the same repo to EKS in timeboxed sessions: `terraform apply`, work, `terraform destroy`. It covers what kind cannot: IAM for workloads, real load balancers, node autoscaling, spot, and GPU serving with vLLM.

### Prerequisites (start these during Stage 1)

- Personal AWS account: MFA on root, an admin IAM Identity Center user, no long-lived access keys.
- **GPU quota:** request Service Quotas increases for "Running On-Demand G and VT instances" and "All G and VT Spot Instance Requests" (e.g. 8 vCPUs). New accounts often start at 0, and approval can take days. Request in week 1, and ask for 48 vCPUs if you plan the multi-GPU run in 2.6.
- AWS Budgets alerts at $10 / $25 / $50.
- Terraform remote state in S3 with state locking.
- Tag every resource `project=mlops-lab`.

---

### 2.1 Terraform EKS baseline (week 11)

- VPC across 2 AZs with public subnets only (no NAT gateway for the lab).
- EKS on a version in standard support; managed node group of 2 small on-demand instances (e.g. t3.large) for system pods.
- Add-ons: VPC CNI, CoreDNS, kube-proxy, EBS CSI driver, EKS Pod Identity agent.
- ECR repositories, an S3 bucket for model weights (versioning on), Pod Identity/IRSA roles.
- ArgoCD bootstrapped against the same repo with `overlays/eks`.
- **Done when:** `terraform apply` + ArgoCD sync gives a working platform in under 30 minutes, and destroy leaves no tagged resources behind.

### 2.2 Platform on EKS (weeks 11–12)

- AWS Load Balancer Controller for Ingress; TLS with ACM or cert-manager; ExternalDNS if you own a domain.
- MinIO → S3 as a config change only. MLflow artifacts in S3 through Pod Identity; Postgres stays in-cluster to save cost.
- CI pushes images to ECR through GitHub OIDC → an AWS role. No static keys anywhere.
- **Done when:** the gateway answers at an HTTPS URL, and pods read S3 with no credentials in config.

### 2.3 GPU nodes (week 12)

- Karpenter with a GPU NodePool: g6.xlarge (L4) or g5.xlarge (A10G), spot first with on-demand fallback, taint `nvidia.com/gpu`, consolidation on.
- NVIDIA GPU Operator (or the EKS accelerated AMI + device plugin), plus DCGM exporter.
- **Done when:** a pod requesting `nvidia.com/gpu: 1` makes Karpenter launch a node and `nvidia-smi` runs. Record the provisioning time.

### 2.4 vLLM serving (week 13)

- vLLM image mirrored to ECR. Weights (safetensors, e.g. Qwen2.5-7B-Instruct-AWQ or Llama-3.1-8B-Instruct) pulled from S3 to local NVMe at startup.
- Tune `--max-model-len`, `--gpu-memory-utilization`, `--max-num-seqs` and quantization; enable prefix caching.
- Register vLLM as a third LiteLLM backend.
- Break cold start down into node boot, image pull, weight download and model load. Try one fix: a pre-pulled image, cached weights, or a slimmer image.
- **Done when:** the vLLM endpoint serves through the gateway, with a documented cold-start breakdown before and after your fix.

### 2.5 Autoscaling, performance and cost (week 14)

- KEDA ScaledObject on vLLM's waiting-requests metric → more replicas → Karpenter adds GPU nodes; optional scale to zero when idle.
- k6 sweep from 1 to 64 concurrent users: TTFT, time per output token, throughput, GPU utilization from DCGM. Compare two configs (e.g. AWQ vs FP16).
- Cost per 1M output tokens = node $/hour ÷ (output tokens/hour) × 1,000,000.
- The same eval gate from 1.7 runs against vLLM model versions before promotion.
- Spot interruption drill: terminate the GPU node (manually or with AWS FIS) and verify recovery.
- **Done when:** Grafana shows scale-out under load and scale-in after, and a cost-per-token table is in `docs/`.

### 2.6 Training on GPUs (weeks 15–16)

- Run the 1.8 pipeline on EKS: LoRA fine-tune of a 7–8B model on one spot GPU as a Kubernetes Job, data and checkpoints in S3 through Pod Identity.
- **Kueue** for GPU job queueing: a ClusterQueue with a GPU quota, two LocalQueues (e.g. `training` and `experiments`) with different priorities; check that a high-priority job preempts a low-priority one.
- Alternative or extra: **KubeRay** with a RayJob for the same fine-tune, to compare the two scheduling models.
- Checkpoint to S3 every N steps. Spot drill: terminate the node mid-run and confirm the job resumes from the last checkpoint on a new node.
- GPU utilization and throughput (samples/sec) on the Grafana dashboard via DCGM; cost per training run recorded in MLflow.
- Optional stretch: a short multi-GPU run with PyTorch DDP or FSDP (`torchrun`) on a 4-GPU instance (e.g. g6.12xlarge, roughly $4–5/hr on demand; much less on spot). Compare samples/sec against the single-GPU run.
- The fine-tuned model registers in MLflow, passes the eval gate, and is served by vLLM from 2.4.
- **Done when:** a queued GPU training job survives a spot interruption, and its output model reaches vLLM through the eval gate.

### 2.7 Teardown automation (every session)

- `make eks-up` / `make eks-down`. The down script deletes Ingresses, LoadBalancer Services and PVCs first, waits for the ALBs and EBS volumes to disappear, then runs `terraform destroy`.
- Finish every session with a Resource Groups search for `project=mlops-lab`.

---

## Stage 2 Exit Criteria and Cost Guardrails

- [ ] `make eks-up` → working platform with HTTPS gateway in under 30 minutes; `make eks-down` leaves nothing tagged
- [ ] Pods reach S3 and ECR through Pod Identity/IRSA, with no static credentials anywhere
- [ ] Karpenter launches spot GPU nodes on demand and consolidates them away
- [ ] vLLM serves through the gateway, with a cold-start breakdown and one optimization measured
- [ ] KEDA scales vLLM on queue depth under a k6 sweep
- [ ] Cost per 1M tokens and TTFT/throughput curves documented for two configs
- [ ] Eval gate promotes vLLM model versions just as in Stage 1
- [ ] Spot interruption drill passed and written up
- [ ] Kueue-queued GPU training job resumes from an S3 checkpoint after a spot interruption

### Estimated cost per 4-hour session

> Approximate us-east-1 prices — check AWS pricing before relying on them.

| Item | Approx. cost |
|---|---|
| EKS control plane ($0.10/hr) | $0.40 |
| 2 × t3.large system nodes | ~$0.70 |
| 1 spot GPU node (g6/g5.xlarge) | ~$1–2 |
| Load balancer, EBS, S3 | ~$0.20 |
| **Total** | **~$2.50–3.50** |

About 12–14 sessions puts Stage 2 at roughly $40–70, plus about $10–20 if you do the optional multi-GPU run. The real risk is resources left running: a cluster plus one GPU left on for a month costs $600+.

### Guardrails

- Budgets alerts at $10 / $25 / $50, plus a calendar reminder to run `make eks-down`.
- Spot for GPU and worker nodes; no NAT gateway; single region.
- Delete Kubernetes-created ALBs and EBS volumes before `terraform destroy`, since Terraform does not track them.
- Check Cost Explorer weekly while Stage 2 is active.

---

## Timeline

| Week | Milestone |
|---|---|
| 1 | 1.1 Cluster + GitOps · **Request AWS GPU quota** |
| 2 | 1.2 Storage + model registry |
| 3 | 1.3 In-cluster serving · 1.4 Host Metal (optional) |
| 4 | 1.5 Gateway + app |
| 5 | 1.6 Observability |
| 6–7 | 1.7 Eval gate + load testing |
| 8–9 | 1.8 Training pipeline |
| 10 | Buffer + Stage 1 write-up · **Stage 1 exit gate** |
| 11 | 2.1 Terraform EKS baseline · 2.2 Platform on EKS (start) |
| 12 | 2.2 Platform on EKS (finish) · 2.3 GPU nodes |
| 13 | 2.4 vLLM serving |
| 14 | 2.5 Autoscaling, performance and cost |
| 15–16 | 2.6 Training on GPUs |
| Every Stage 2 session | 2.7 Teardown automation |

> Stage 2 starts only after the Stage 1 exit gate in week 10.

---

## Gotchas and Break-it Drills

### Known gotchas

- Docker Desktop's VM caps memory. Model weights + Prometheus + MLflow can OOM the whole kind cluster. Start with 1–3B models in-cluster.
- kind has no `LoadBalancer` support out of the box. Use Ingress, or cloud-provider-kind if you need one.
- llama.cpp (GGUF) and vLLM (safetensors) use different weight formats. The registry needs a `format` tag, and each serving image accepts only its own format.
- Model load time breaks naive probes. Use a startupProbe with a long enough threshold, or pods restart in a loop.
- On EKS, Terraform does not know about ALBs or EBS volumes created from Kubernetes. Delete those first, or `destroy` hangs and money leaks.
- GPU quota is often 0 on new AWS accounts. Request it early.

### Break-it drills

Write each one up in `docs/incidents/`.

1. Kill a worker node mid-rollout; check that requests keep succeeding.
2. Register a corrupt or wrong-format model; the init step or eval gate must catch it.
3. Fill the model volume's disk; confirm alerts fire and pods fail clearly.
4. Overload the gateway past its rate limits; check 429s, not crashes.
5. Take a backend down; confirm LiteLLM fallback and the alert.
6. (Stage 2) Terminate the spot GPU node under load; measure time to recover.
7. (Stage 2) Revoke the pod's S3 permission; confirm the failure is visible and clearly explained.
8. Push a malformed training batch; data validation must fail the pipeline before training starts.
9. (Stage 2) Kill a training pod mid-run; confirm it resumes from the last S3 checkpoint.
