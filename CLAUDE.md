# CloudFormation POC — One-Command Provisioning for New Backend Services (BeED)

## Context
Sandy (Architect/DevOps) manually provisions ALB + Target Group + ECS Fargate + supporting resources every time a new backend service launches (~12 console steps). The wiki (BEED-DEPL-001) confirms deployments are fully manual via `deploy.sh`; a CI/CD POC is on the Q2 2026 roadmap. Goal: build a CloudFormation POC in this repo that provisions a complete per-service stack in one command, demoed live from Vincent's personal AWS account (345989055312, ap-southeast-1), then present to Sandy.

- Production AWS account: `241486781178` (ap-southeast-1) — Vincent has **read-only** access (no CLI keys, console only).
- Demo/deploy account: Vincent's personal `345989055312` (CLI profile `default`).
- Current deploy flow: fully manual `deploy.sh` (docker build linux/amd64 → ECR push → register-task-definition → update-service). No CI/CD.

**User decisions:** live demo in personal account; deliver BOTH (A) parity + safe improvements and (B) full best-practice redesign, each with explained rationale.

## Observed production patterns (account 241486781178, ap-southeast-1)

| Resource | Observed pattern (hub-api prod example) |
|---|---|
| ECS Cluster | `hub-api-cluster-prod` — one cluster per service per env (22 clusters) |
| ECS Service | Console-wizard name `Hub-API-prod-task-service-wu0ns4py`, Fargate, REPLICA, desired 1, platform 1.4.0 |
| Task Definition | family `Hub-API-prod-task`, container `hub-api-prod`, cpu 1024 / mem 3072, X86_64, awsvpc |
| Image | ECR `<service>-<env>-repo:vX.Y.Z` (`hub-api-prod-repo:v1.3.46`) |
| Env vars | S3 env file `s3://acdstagingbucket/setting-<svc>/<svc>-<env>.env` (staging bucket even for prod) |
| Logging | awslogs `/ecs/<family>`, create-group true, prefix `ecs`, no retention set |
| IAM | ONE shared `ecsTaskExecutionRole` as BOTH task+execution role; per-service inline policies `ecs-<svc>-read-appsetting-policy` (S3 read) appended — 8 policies already (limit 10 managed) |
| ALB | Dedicated ALB per service `Beed-Hub-API-Prod` — 25 ALBs (~$400+/mo fixed) |
| Listeners | HTTP:80 → 301 to HTTPS; HTTPS:443 → TG, ACM `*.beed.world`, ELBSecurityPolicy-TLS13-1-2 |
| Target Group | `BeED-Hub-API-Prod-Target-Goup` (typo shipped to prod), target type IP, HC: HTTP `/health` traffic-port 30s/5s, 5 healthy/2 unhealthy, 200 |
| Networking | Default VPC `vpc-df22d8bb` (172.31/16), 3 default PUBLIC subnets, tasks get public IPs, task SG = default VPC SG (**All TCP from 0.0.0.0/0**); ALB reuses 5 shared org SGs |
| DNS | `beed.world` managed OUTSIDE AWS (R53 has only unused `beed.site`); CNAME to ALB DNS created manually |

Known BeED services: hub-api, gatekeeper, connect, experio-api, unified-library, sms, bmeet, greenlight, liam-ui, rag-api, journeys, beed-ops-console. Envs: test, stage, prod.

### Pain points the POC demonstrates fixing
1. ~12 manual steps per service → one `aws cloudformation deploy`.
2. Naming typos/inconsistency (`Target-Goup`, `greenligt`) → templated names.
3. Wide-open default SG + public task IPs → scoped SG chain.
4. Shared execution role near policy limit → per-service roles.
5. No rollback/drift management → CloudFormation stack lifecycle + ECS circuit breaker.

## POC Design

### Repo layout
```
cloud-formation-poc/
├── README.md                          # architecture, rationale for A vs B, demo script
├── option-a-parity/
│   ├── backend-service.yaml           # single self-contained template per service
│   └── params/demo-service-dev.json
├── option-b-redesign/
│   ├── platform-stack.yaml            # deploy ONCE: VPC, shared ALB, shared cluster
│   ├── service-stack.yaml             # deploy PER SERVICE: TG, listener rule, service
│   └── params/{platform-demo.json, demo-service-dev.json}
└── scripts/{deploy.ps1, deploy.sh}    # thin wrappers over aws cloudformation deploy
```

### Option A — Parity + safe improvements (`option-a-parity/backend-service.yaml`)
Mirrors today's topology so it drops straight into Sandy's workflow: dedicated ALB per service, default-VPC public subnets, public task IPs (no NAT exists), S3 env files, same naming scheme (typo-free), same health-check numbers.

Parameters: `ServiceName` (e.g. hub-api), `Environment` (test|stage|prod), `ContainerPort` (e.g. 4100), `ImageUri`, `Cpu`=1024, `Memory`=3072, `DesiredCount`=1, `VpcId`, `SubnetIds` (public), `CertificateArn` (optional — `HasCertificate` condition skips HTTPS listener for demo), `HealthCheckPath`=/health, `EnvFileS3Bucket`/`EnvFileS3Key` (optional), `LogRetentionDays`=30.

Resources: cluster, ALB-SG (80/443 from 0.0.0.0/0), Task-SG (ContainerPort from ALB-SG only), ALB `BeED-${ServiceName}-${Environment}`, TG (ip type, HC parity), HTTP→HTTPS redirect listener, HTTPS listener, log group, per-service execution role (managed ECS policy + scoped S3 env read), separate empty task role, task definition, service with deployment circuit breaker + rollback. Outputs: ALB DNS (for the manual external CNAME), names/ARNs.

Safe improvements over parity — each documented in README with WHY:
1. **Task SG only accepts traffic from the ALB SG** (today: default SG, all TCP from the whole internet, on tasks with public IPs — anyone can hit port 4100 directly, bypassing TLS/ALB).
2. **Per-service execution role + separate task role** (today: one role shared by all services is both task & execution role — any container can read every service's settings; and the role is 2 policies away from the 10-policy cap, i.e. the current process breaks in ~2 more services).
3. **Log retention parameter** (today: never-expire logs = silent cost growth).
4. **ECS deployment circuit breaker with auto-rollback** (today: rollback is a manual 6-step runbook, Section 9 of the wiki).
5. **Deterministic names** (today: console wizard suffixes like `-wu0ns4py` and typos shipped to prod).

### Option B — Best-practice redesign (`option-b-redesign/`)
Two-tier: shared platform deployed once, then each new service is a tiny cheap stack.

`platform-stack.yaml` (once per env): purpose-built VPC (2 AZ, public subnets for ALB, private subnets for tasks, single NAT gateway with a `NatPerAz` param), ONE shared internet-facing ALB + HTTP→HTTPS + HTTPS listener (wildcard cert), ONE shared ECS cluster, ALB SG. Exports via `Fn::Export`.

`service-stack.yaml` (per service): TG, **host-based listener rule** (`<service>-<env>.beed.world` → TG, priority param), task SG (from ALB SG only), per-service roles, log group, task definition (env from **Secrets Manager/SSM Parameter Store** instead of S3 .env), service in private subnets (no public IP), **target-tracking autoscaling** (CPU 70%, min/max params).

Why best practice vs current topology (README section):
1. **Shared ALB + host rules**: 25 dedicated ALBs ≈ $400+/mo fixed cost doing nothing; one ALB per env handles all services (up to 100 rules), new service adds $0 fixed cost.
2. **Private subnets + NAT**: tasks unreachable from the internet — the ALB is the only door; removes the current "public IP + open SG" exposure entirely rather than patching it.
3. **Shared cluster**: clusters are free logical groupings, but 22 single-service clusters make ops (capacity providers, Container Insights, exec) 22x work; one cluster per env matches the fault-isolation ECS actually provides.
4. **Secrets Manager/SSM over S3 .env**: rotation, audit trail (CloudTrail per-secret access), no plaintext prod credentials in a bucket literally named `acdstagingbucket`, per-service resource-level IAM.
5. **Autoscaling**: desired=1 fixed today — a deploy or task crash = downtime; min 2 across AZs + target tracking is genuine HA.
6. **Cross-stack exports**: platform team owns the platform stack; service stacks can't accidentally mutate shared infra.
Trade-offs stated honestly: NAT gateway ~$36/mo/AZ + data processing; migration of 22 services is incremental (both options coexist — a service can move one at a time).

### Demo script (README, run in personal account 345989055312)
1. Option A: `aws cloudformation deploy --template-file option-a-parity/backend-service.yaml --stack-name demo-hub-api-dev --parameter-overrides file://... --capabilities CAPABILITY_NAMED_IAM` with a public sample image (nginx or hashicorp/http-echo with `/health`); curl ALB DNS → 200. Show update (new ImageUri) → rolling deploy; show circuit-breaker rollback with a broken image tag if time allows.
2. Option B: deploy platform stack once (~5 min, NAT), then deploy TWO service stacks in ~2 min each onto the same ALB → the "new service in 2 minutes at zero added cost" money shot.
3. `delete-stack` everything.

## Verification
1. `aws cloudformation validate-template` + `cfn-lint` (pip install) on all 3 templates.
2. Live deploy Option A to personal account: CREATE_COMPLETE, TG target healthy, `curl http://<alb-dns>/health` = 200. Tear down.
3. Live deploy Option B platform + one service: same checks via host-header curl (`curl -H "Host: demo.example.com" http://<alb-dns>/health`). Tear down (verify NAT/EIP released).
4. Confirm delete leaves no orphans (log groups have DeletionPolicy Delete).

## Out of scope
- The CI/CD pipeline itself (GitHub Actions) — this POC is the infra half; README notes how a pipeline would call these stacks.
- Frontend (S3+CloudFront), RDS, Redis provisioning; DNS automation (beed.world is external — stack outputs the CNAME target).
- Migrating the existing 22 services.
