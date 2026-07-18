# Option B — Safe Improvements (implementation line map)

The same five safe improvements as Option A, plus the redesign-specific pieces,
showing exactly where and how they're implemented in
[`service-stack.yaml`](./service-stack.yaml). Line numbers refer to the current
version of that file.

> Option B is the best-practice redesign: services run on a shared platform stack
> (one VPC, one ALB, one cluster per environment) and attach via cross-stack imports.
> So a few improvements are implemented a little differently than in Option A — noted below.

---

## 1. Task SG only accepts traffic from the ALB SG

One firewall on the task, trusting only the shared ALB:

- `TaskSecurityGroup` (lines 132–145) — the task's firewall. The improvement is lines 143–144: `SourceSecurityGroupId: !ImportValue ...AlbSecurityGroupId`, combined with the port on lines 141–142. Instead of a CIDR like `0.0.0.0/0`, the source is the shared ALB's security group, so only traffic coming through that ALB is allowed, only on the container port.
- It's attached to the service at lines 286–287 (`SecurityGroups: - !Ref TaskSecurityGroup`).
- Difference from Option A: the ALB security group is imported from the platform stack (shared ALB), not created here.

**Before:** tasks used the default VPC SG (all TCP from `0.0.0.0/0`) with public IPs. **After:** the task is reachable only via the shared ALB.

## 2. Per-service execution role + separate task role

Two distinct IAM roles, with each permission as its own attachable policy:

- `ExecutionRole` (lines 158–170) — named per-service (line 161), gets the standard managed policy (line 170).
- `EnvFileReadPolicy` (lines 175–190) — a separate resource attached to the execution role only when an env file is used (`Condition: HasEnvFile`); scoped to that single env file (line 187).
- `SecretReadPolicy` (lines 193–205) — a separate resource attached only when a secret is used (`Condition: HasSecret`); scoped to that single secret (line 205).
- `TaskRole` (lines 208–218) — a separate role, per-service (line 211), deliberately empty = least privilege.
- They're wired in as two different roles on the task definition: line 232 `ExecutionRoleArn: !GetAtt ExecutionRole.Arn` and line 233 `TaskRoleArn: !GetAtt TaskRole.Arn`.
- Difference from Option A: the scoped permissions are their own resources (not inline), so an env file and a secret can each be attached independently.

**Before:** one shared `ecsTaskExecutionRole` was both roles for every service, so any container (and its app code) could read every service's config/secrets. **After:** each service has its own execution role (scoped to its own settings) and its own task role.

## 3. Log retention parameter

One parameter, applied to the log group:

- The parameter `LogRetentionDays` is declared at lines 78–81 (default 30).
- It's applied on the log group at line 154: `RetentionInDays: !Ref LogRetentionDays`.

**Before:** log groups had no retention set (kept forever, silent cost growth). **After:** logs auto-expire after N days.

## 4. ECS deployment circuit breaker with auto-rollback

One block on the service that watches deployments:

- In the `Service` resource's `DeploymentConfiguration`, the `DeploymentCircuitBreaker` block at lines 276–278: `Enable: true` (line 277) turns on failure detection, `Rollback: true` (line 278) makes a failed deploy automatically revert to the last good task definition.

**Before:** rollback was the manual 6-step runbook in wiki §9. **After:** ECS does it automatically.

## 5. Deterministic names

Every resource name is built from the parameters with `!Sub`, so it's predictable and consistent instead of random. For example:

- Target group: line 97, task SG: line 136, log group: line 153, roles: lines 161/211, task-def family: line 224, service: line 264, scaling policy: line 312.
- Plus input validation so bad names can't sneak in: `AllowedPattern` and `MaxLength` on `ServiceName` (lines 21–22) and `AllowedValues` on `Environment` (line 26).

**Before:** console-wizard suffixes like `-wu0ns4py` and typos (`Target-Goup`). **After:** every name is derived from the same validated `ServiceName`, so it's spelled consistently everywhere.

---

## Plus the Option-B-only redesign pieces (not in Option A)

These are the changes that make Option B a redesign rather than parity:

- **Shared ALB via host-based routing** (instead of a dedicated ALB per service): `ListenerRule` (lines 116–129) — matches the `Host` header (lines 122–126) and attaches to the platform's shared listener imported at lines 119–120. One ALB serves all services, so a new service adds zero fixed ALB cost.
- **Private subnets, no public IP:** service `NetworkConfiguration` (lines 279–287); key line 281 `AssignPublicIp: DISABLED`; private subnets imported at lines 282–285. The task reaches S3/ECR through the NAT gateway and is never exposed to inbound internet traffic.
- **Autoscaling (target-tracking on CPU):** `ScalableTarget` (lines 295–305; min/max at lines 304–305) and `ScalingPolicy` (lines 309–320; CPU target at lines 316–318).
- **Cross-stack imports** that plug the service into the platform: `!ImportValue` at lines 98–99 (VPC), 119–120 (listener), 143–144 (ALB SG), 265–266 (cluster), 284–285 (private subnets).
