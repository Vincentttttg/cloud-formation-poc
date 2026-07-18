# Option A — Manual Console Runbook (the "pain" way)

Provision the **same** stack as `backend-service.yaml`, but **by hand in the AWS
Console**, so you feel exactly what the one-command deploy automates. Each step
ends with `↔ CFN:` showing which template resource it corresponds to.

> **Account:** do this in your **personal** account (`345989055312`), region
> **ap-southeast-1** — NOT the read-only prod account.
> **Image:** we use the public `public.ecr.aws/docker/library/nginx:alpine`, so no
> ECR repo or image build is needed.
> **Cost:** the ALB bills ~\$0.03/hr while it exists. **Do the cleanup at the end.**
> **Your VPC (personal default):** `vpc-07c712dd87ab54541`
> **Your subnets:** `subnet-0a71099444f9e3dd2` (1a), `subnet-0175d233e8c89b102` (1b), `subnet-0bc31a2daba3cfe8a` (1c)

Fill these in as you go: **ServiceName** = `demo-api`, **Environment** = `test`,
**ContainerPort** = `80`.

---

## Order matters
Build bottom-up so each thing exists before the thing that references it:
**Security groups → Target group → Load balancer + listener → Log group → IAM roles → Task definition → Cluster → Service → verify.**

---

## Step 1 — Security groups  ↔ CFN: `AlbSecurityGroup`, `TaskSecurityGroup`
EC2 → **Security Groups** → **Create security group** (do this twice):

**a) ALB SG** — name `beed-demo-api-test-alb-sg`, VPC = your default VPC. Inbound rules:
- HTTP, TCP 80, Source `0.0.0.0/0`
- HTTPS, TCP 443, Source `0.0.0.0/0`

**b) Task SG** — name `beed-demo-api-test-task-sg`, same VPC. Inbound rule:
- Custom TCP, port **80** (your ContainerPort), Source = **the ALB SG** you just made (pick it from the dropdown, not a CIDR).

> This SG chain is the whole security improvement: the task only accepts traffic
> from the ALB, never from the internet directly.

## Step 2 — Target group  ↔ CFN: `TargetGroup`
EC2 → **Target Groups** → **Create target group**:
- Target type: **IP addresses** (required for Fargate).
- Name `BeED-demo-api-test-tg`, Protocol **HTTP**, Port **80**, your VPC.
- Health checks → Path `/` (nginx serves `/`; real services use `/health`).
- Advanced health check: interval **30s**, timeout **5s**, healthy **5**, unhealthy **2**, success codes **200**.
- **Do NOT register any targets** — ECS registers the task automatically. Click through and Create.

## Step 3 — Application Load Balancer + HTTP listener  ↔ CFN: `LoadBalancer`, `HttpListener`
EC2 → **Load Balancers** → **Create load balancer** → **Application Load Balancer**:
- Name `BeED-demo-api-test`, Scheme **Internet-facing**, IP type IPv4.
- Network: your VPC, and tick **at least two** subnets in different AZs (use your 1a + 1b).
- Security groups: select the **ALB SG** (remove the default SG).
- Listeners: **HTTP:80** → Default action **Forward to** → your target group `BeED-demo-api-test-tg`.
- Create. (HTTPS:443 would need an ACM cert — skip for this demo.)

## Step 4 — CloudWatch log group  ↔ CFN: `LogGroup`
CloudWatch → **Log groups** → **Create log group**:
- Name `/ecs/demo-api-test-task`, Retention **30 days**.

> ECS can auto-create this, but creating it yourself is part of the manual flow
> (and lets you set retention, which the auto-created ones don't have).

## Step 5 — IAM roles  ↔ CFN: `ExecutionRole`, `TaskRole`
IAM → **Roles** → **Create role** (twice), Trusted entity: **AWS service → Elastic Container Service → Elastic Container Service Task**:

**a) Execution role** — name `demo-api-test-execution-role`, attach policy **AmazonECSTaskExecutionRolePolicy**. (If you were using an S3 env file, you'd also add an inline `s3:GetObject` policy scoped to that file.)

**b) Task role** — name `demo-api-test-task-role`, **attach nothing** (empty = least privilege).

> This is the improvement over prod, where one shared `ecsTaskExecutionRole` is
> used as both roles for every service. Notice the ECS wizard will *offer* to
> auto-create/reuse a single `ecsTaskExecutionRole` — that convenience is exactly
> how the shared-role sprawl happens.

## Step 6 — Task definition  ↔ CFN: `TaskDefinition`
ECS → **Task definitions** → **Create new task definition**:
- Family `demo-api-test-task`.
- Launch type **AWS Fargate**, OS **Linux/X86_64**.
- Task size: CPU **0.25 vCPU** (256), Memory **0.5 GB** (512). *(Real prod uses 1024/3072.)*
- **Task role** = `demo-api-test-task-role`; **Task execution role** = `demo-api-test-execution-role`.
- Container:
  - Name `demo-api-test`, Image URI `public.ecr.aws/docker/library/nginx:alpine`.
  - Port mappings: container port **80**, TCP.
  - Logging: use **awslogs**, pointing at log group `/ecs/demo-api-test-task`.
- Create.

## Step 7 — ECS cluster  ↔ CFN: `Cluster`
ECS → **Clusters** → **Create cluster**:
- Name `demo-api-cluster-test`, Infrastructure **AWS Fargate**. Create.

## Step 8 — ECS service  ↔ CFN: `Service`
Open `demo-api-cluster-test` → **Services** → **Create**:
- Compute: **Launch type**, **FARGATE**.
- Deployment: **Service**, Family `demo-api-test-task` (latest revision), Service name `demo-api-test-service`, Desired tasks **1**.
- Networking: your VPC, your subnets; **Security group** = the **Task SG** (remove default); **Public IP: Turned ON** *(parity — the default VPC has no NAT, so the task needs a public IP to pull the image)*.
- Load balancing: **Application Load Balancer** → **Use an existing load balancer** `BeED-demo-api-test` → container `demo-api-test:80` → **Use an existing target group** `BeED-demo-api-test-tg`.
- (Advanced/Deployment options: enable **Deployment circuit breaker** + **Rollback** if offered.)
- Create.

## Step 9 — Verify  ↔ CFN: outputs + your `curl`
- EC2 → Target Groups → `BeED-demo-api-test-tg` → **Targets** tab → wait until the task shows **healthy** (a few minutes).
- EC2 → Load Balancers → `BeED-demo-api-test` → copy the **DNS name** → open `http://<that-dns>/` in a browser. You should get the **nginx welcome page**.

## Step 10 — DNS (real world only)
In prod you'd now create a CNAME `demo-api.beed.world → <ALB DNS>` in the external
DNS provider. Skip for the demo.

---

## Cleanup (IMPORTANT — reverse order, or you keep paying for the ALB)
1. ECS → cluster → delete the **service** (force).
2. ECS → delete the **cluster**.
3. EC2 → Load Balancers → delete the **ALB**.
4. EC2 → Target Groups → delete the **target group**.
5. ECS → Task definitions → deregister the **task definition** revision.
6. CloudWatch → delete the **log group** `/ecs/demo-api-test-task`.
7. EC2 → Security Groups → delete the **task SG**, then the **ALB SG** (task SG first, since it references the ALB SG).
8. IAM → delete the two **roles**.

### What actually costs money (and what's free)

The rule of thumb: **you pay for running capacity and networking, not for
configuration objects.** That's why the cleanup order deletes the ALB and service
first — they're the meters — and everything else can be deleted at your leisure.

**Costs money (while it exists):**

| Resource | Charge | Rough cost (Singapore) |
|---|---|---|
| **ALB** | Billed **per hour just for existing**, regardless of traffic (+ small LCU for traffic) | ~$0.0225/hr ≈ **$16–18/month** |
| **Fargate task** (the running container) | Per second for **vCPU + memory** while running; stops when you delete the service | 0.25 vCPU / 0.5 GB ≈ **~$0.012–0.015/hr ≈ $9–11/month** if left 24/7 |
| **Public IPv4 address** | ~$0.005/hr **per public IP** (the ALB's IPs + the task's public IP) | a few $/month, minor |
| **CloudWatch Logs** | Data **ingested + stored** (~$0.50/GB in, ~$0.03/GB-month stored) | a demo's logs ≈ pennies |

**Free (no charge for the resource itself):**

| Resource | Why it's free |
|---|---|
| **ECS Cluster** | Logical grouping — no charge for the cluster object. |
| **ECS Service** | Just the scheduler that keeps your task count. You pay for the *tasks*, not the service. |
| **Target Group** | Pure config — a routing target + health-check rules. |
| **Task Definition** | A JSON blueprint; the *running task* costs, the recipe doesn't. |
| **Security Groups** | Firewall rules — always free. |
| **IAM Roles** | Permissions — always free. |

**Takeaway:** the only real meters are the **ALB (~$16+/mo, fixed)** and the
**Fargate task (~$9–11/mo if 24/7)**; the resources you spent the most *clicks* on
are free configuration. For a short demo the total is cents — the danger is only if
you **leave it running**, and the ALB is the slow leak. This is also the core of the
Option B argument: 25 services × one ALB each ≈ **$400+/month in fixed ALB charges**
alone, which a single shared ALB with host-based rules removes (the Fargate tasks
cost the same either way).

---

## The point
Count the distinct create screens you just went through: **~10–12**, across 4
different console services (EC2, ECS, CloudWatch, IAM), each with fields you had
to get right and wire to the previous one — and that's for **one** service in
**one** environment. `backend-service.yaml` does all of it from a single
`aws cloudformation deploy`, and `teardown.sh` undoes it in one command instead
of the 8-step cleanup above.
