# BeED CloudFormation POC — New Backend Service in One Command

**Problem.** Launching a new backend service today takes ~12 manual console steps
(ECR repo, S3 env file, IAM policy, target group, dedicated ALB, two listeners,
cluster, task definition, service, health verification, DNS) — repeated for each
of test / stage / prod, so a fully rolled-out service is roughly **36 manual
steps**, all performed by one person. This POC replaces the AWS-side steps with
a single `aws cloudformation deploy`.

Two options are included, both fully working:

| | Option A — Parity + safe improvements | Option B — Best-practice redesign |
|---|---|---|
| Topology | Same as today: dedicated ALB per service, default VPC, public subnets | Shared ALB + host-based routing, purpose-built VPC, private subnets + NAT |
| Migration effort | Drop-in — matches existing naming and workflow | New platform layer; services migrate one at a time |
| Fixed cost per new service | ~\$16+/mo (its own ALB) | \$0 (rides the shared ALB) |
| Stacks per service | 1 | 1 (plus one shared platform stack per env) |

```
option-a-parity/
  backend-service.yaml        # everything for one service, one deploy
  params/demo-service-dev.json
  params/demo-service-envfile.json  # demo params that reference an S3 env file
  params/example-prod.json    # values mirroring the real hub-api prod setup
option-b-redesign/
  platform-stack.yaml         # ONCE per env: VPC, shared ALB, shared cluster
  service-stack.yaml          # PER service: TG, listener rule, service, autoscaling
  params/...
env-file/                     # shared across BOTH options (DRY)
  envfile-bucket.yaml         # S3 bucket for a service's .env settings file
  sample-service.env          # sample settings file to upload
scripts/
  validate.sh                 # validate-template + cfn-lint on all templates
  deploy.sh                   # thin wrapper (+ optional S3 env-file upload/bucket)
  teardown.sh                 # delete a stack (+ optional S3 env-file cleanup)
  quick-test.sh               # Option A end-to-end: validate -> deploy -> curl -> teardown
```

## Scripts

All Bash (run from Git Bash or WSL on Windows). Defaults target the demo account /
`ap-southeast-1`; override with trailing `[region] [profile]` args.

```bash
# Check all three templates before deploying (structure + deep lint):
./scripts/validate.sh

# Deploy any template:
./scripts/deploy.sh <template.yaml> <stack-name> <params.json>

# Delete a stack when done (add the params file if the stack used an env file):
./scripts/teardown.sh <stack-name> [params.json]

# One-shot smoke test of Option A: validate, deploy, curl the ALB until it
# returns 200, then tear the stack down automatically:
./scripts/quick-test.sh
# ...leave it running afterwards instead of deleting (to poke at it):
KEEP=1 ./scripts/quick-test.sh
```

### The S3 env-file pattern (built into `deploy.sh` / `teardown.sh`)

BeED services load config from an S3 `.env` file rather than baking it into the
image. `deploy.sh` handles this automatically: **if the params file references an
env file** (`EnvFileS3Bucket` + `EnvFileS3Key`), it can upload the file — and
optionally create the bucket — *before* deploying. This matters because an ECS
task downloads its env file from S3 **before the container starts**, so the file
must already be there or the task fails to launch. It works for **both options**
(any params file that names an env file).

Two env variables control it (they do nothing when the params don't reference an
env file, so `deploy.sh` stays a plain wrapper the rest of the time):

- `ENV_FILE=<path>` — a local `.env` to upload to S3 before deploying. Omit it to
  assume the file is already in S3 (the real BeED case — the shared bucket exists
  and settings were uploaded once).
- `CREATE_BUCKET=1` — also create the bucket first, as a `<stack>-envbucket` stack.
  Only for a throwaway demo; real deploys leave it off because the shared bucket
  (like `acdstagingbucket`) already exists.

`teardown.sh` mirrors it: pass the **params file as the 2nd argument** (same
position idea as `deploy.sh`, where the params file also comes before
region/profile) and it removes what the deploy added — the **demo bucket** if
`deploy.sh` created one, otherwise just **this service's `.env` object** (the
shared bucket and other services' files are left untouched). Omit it for a stack
with no env file.

```bash
# Self-contained env-file demo, Option A (create bucket, upload, deploy, then clean up):
ENV_FILE=env-file/sample-service.env CREATE_BUCKET=1 \
  ./scripts/deploy.sh option-a-parity/backend-service.yaml demo-a-env \
  option-a-parity/params/demo-service-envfile.json

curl http://<AlbDnsName>/                                  # 200 = task read the .env from S3

./scripts/teardown.sh demo-a-env \
  option-a-parity/params/demo-service-envfile.json         # removes the .env + the demo bucket

# Same for Option B (after the platform stack is up) — its task runs in a PRIVATE
# subnet and pulls the .env from S3 through the NAT gateway:
ENV_FILE=env-file/sample-service.env CREATE_BUCKET=1 \
  ./scripts/deploy.sh option-b-redesign/service-stack.yaml demo-b-env \
  option-b-redesign/params/demo-service-envfile.json
```

A real deploy is just the same command with the env vars omitted (bucket already
exists, file already uploaded), e.g. params pointing at `acdstagingbucket`.

`quick-test.sh` tears down even if the deploy or the curl fails, so it never
leaves a half-broken stack (or its hourly ALB charge) behind unless you pass
`KEEP=1`.

---

## Option A — parity with today, minus the sharp edges

`option-a-parity/backend-service.yaml` provisions, in one stack: ECS cluster
(`<service>-cluster-<env>`), dedicated ALB (`BeED-<Service>-<Env>`), target
group with the standard `/health` check (30s interval / 5s timeout / 5 healthy /
2 unhealthy), HTTP→HTTPS redirect + HTTPS listener (wildcard cert), security
groups, log group, per-service IAM roles, Fargate task definition (S3 env-file
pattern supported) and the service. Naming matches the existing convention so it
slots into `deploy.sh` and the wiki process unchanged.

**Safe improvements over the current manual setup — and why:**

1. **Task security group accepts traffic only from the ALB's security group.**
   Today tasks run in the default VPC security group, which allows **all TCP
   from 0.0.0.0/0**, and tasks have public IPs — anyone on the internet can hit
   the container port directly, bypassing the ALB and TLS entirely.
2. **Per-service execution role, and a separate (empty) task role.** Today one
   shared `ecsTaskExecutionRole` is used as both execution *and* task role for
   every service, so any container can read every other service's settings.
   That role already carries 8 policies; at 10 the current process physically
   stops working (IAM cap). Per-service roles remove both problems.
3. **Log retention (default 30 days, parameterised).** Current log groups never
   expire — storage cost grows forever, silently.
4. **ECS deployment circuit breaker with automatic rollback.** Today a bad
   deploy means a 6-step manual rollback runbook (wiki §9). With the breaker, a
   deployment whose tasks never become healthy rolls back to the previous task
   definition automatically.
5. **Deterministic names.** No more console-wizard suffixes
   (`...-service-wu0ns4py`) or typos shipped to production
   (`...-Target-Goup`).

Everything else is deliberately identical to production (public subnets, public
task IPs — the default VPC has no NAT — S3 `.env` files, health-check numbers,
cpu/memory defaults 1024/3072).

## Option B — what this should look like long-term

Deploy `platform-stack.yaml` **once per environment**, then each new service is
a small `service-stack.yaml` deploy that attaches to it via cross-stack exports.

**Why each change is best practice vs the current topology:**

1. **One shared ALB with host-based listener rules** (`hub-api-prod.beed.world`
   → its target group). Today there are ~25 dedicated ALBs ≈ **$400+/month of
   fixed cost doing nothing** an ALB rule couldn't do. One ALB per environment
   supports up to ~100 services; a new service adds zero fixed cost.
2. **Private subnets + NAT gateway.** Tasks get no public IP and are unreachable
   from the internet — the ALB is the only door. This *removes* the current
   exposure (public IP + wide-open SG) instead of patching it.
3. **One shared ECS cluster per environment.** Clusters are free logical
   groupings; 22 single-service clusters just multiply operational surface
   (Container Insights, capacity providers, ECS Exec config) by 22.
4. **Secrets Manager / SSM available for sensitive config.** Option B's service
   template supports an S3 `.env` file (parity with today) **and** a Secrets
   Manager secret — the recommendation is to keep bulk non-secret config in the
   `.env` and move sensitive values (DB passwords, JWT keys) into a secret, which
   adds rotation, per-secret CloudTrail audit, and resource-level IAM — versus
   plaintext credentials in a bucket named `acdstagingbucket`.
5. **Target-tracking autoscaling (CPU 70%), min 2 tasks across 2 AZs.** Today
   every service runs exactly 1 task — a crash or a deploy is downtime. Min 2
   across AZs is genuine high availability; scaling handles load spikes.
6. **Cross-stack exports as the platform/service contract.** The platform team
   owns the platform stack; service stacks physically cannot mutate shared
   infrastructure.

**Honest trade-offs:** NAT gateway ≈ \$36/month/AZ + data processing (single-NAT
mode is the default to halve that; `NatPerAz=true` for full AZ redundancy).
Migration of the existing 22 services is incremental — Options A and B coexist,
one service can move at a time.

---

## Demo script

Prereqs: AWS CLI v2 with credentials for the demo account, region
`ap-southeast-1`, and a Bash shell (Linux/macOS, or Git Bash / WSL on Windows).
All demo params use tiny public images and small task sizes; cost while the
stacks are up is a few cents/hour.

### Option A (~4 minutes to a working service)

```bash
./scripts/deploy.sh option-a-parity/backend-service.yaml demo-api-test option-a-parity/params/demo-service-dev.json
# outputs include AlbDnsName / ServiceUrl
curl http://<AlbDnsName>/          # -> 200 (nginx welcome page)
```

Then show day-2 operations:

```bash
# 1. Rolling update: edit ImageUri in the params file, re-run the same command.
# 2. Auto-rollback: set ImageUri to a broken tag, re-run - circuit breaker
#    rolls back to the previous task definition without intervention.
# 3. Teardown:
aws cloudformation delete-stack --stack-name demo-api-test --region ap-southeast-1
```

### Option B (platform once, then a new service in ~2 minutes)

```bash
# once per environment (~5 min - NAT gateway is the slow part):
./scripts/deploy.sh option-b-redesign/platform-stack.yaml beed-platform-test option-b-redesign/params/platform-demo.json

# each new service (~2 min, zero new fixed-cost infra):
./scripts/deploy.sh option-b-redesign/service-stack.yaml demo-api-svc  option-b-redesign/params/demo-service-dev.json
./scripts/deploy.sh option-b-redesign/service-stack.yaml demo-api2-svc option-b-redesign/params/demo-service2-dev.json

# both services answer on the SAME ALB, routed by host header:
curl -H "Host: demo-api-test.beed.world"  http://<platform AlbDnsName>/   # nginx welcome page
curl -H "Host: demo-api2-test.beed.world" http://<platform AlbDnsName>/   # httpd "It works!"

# teardown (service stacks first, then platform):
aws cloudformation delete-stack --stack-name demo-api-svc  --region ap-southeast-1
aws cloudformation delete-stack --stack-name demo-api2-svc --region ap-southeast-1
aws cloudformation delete-stack --stack-name beed-platform-test --region ap-southeast-1
```

In production the only remaining manual step is the external DNS CNAME
(`beed.world` is not hosted in Route 53): point the service host name at the ALB
DNS name emitted in the stack outputs.

## What stays manual / out of scope

- **CI/CD pipeline** — this POC is the provisioning half. A GitHub Actions
  pipeline would simply run the same `aws cloudformation deploy` with
  `ImageUri` set to the freshly pushed ECR tag (infra changes and image bumps
  become the same operation).
- ECR repository creation, the `.env`/secret content itself, external DNS.
- Frontend (S3 + CloudFront), RDS, Redis.
- Migrating the existing 22 services.

## Validation

```bash
aws cloudformation validate-template --template-body file://option-a-parity/backend-service.yaml
pip install cfn-lint && cfn-lint option-a-parity/*.yaml option-b-redesign/*.yaml
```
