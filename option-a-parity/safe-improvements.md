# Option A — Safe Improvements (implementation line map)

Each "safe improvement" over BeED's current manual setup, showing exactly where and
how it's implemented in [`backend-service.yaml`](./backend-service.yaml). Line
numbers refer to the current version of that file.

> These are deliberately limited, low-risk changes. Everything else in the template
> is faithful parity with the current production topology (dedicated ALB per service,
> default-VPC public subnets, public task IPs, S3 env files, same health-check numbers).

---

## 1. Task SG only accepts traffic from the ALB SG

Two security groups, chained together:

- `AlbSecurityGroup` (lines 108–124) — the ALB's firewall, opens 80/443 to the internet (`CidrIp: 0.0.0.0/0`, lines 118/123).
- `TaskSecurityGroup` (lines 129–140) — the task's firewall. The improvement is line 139: `SourceSecurityGroupId: !Ref AlbSecurityGroup`, combined with the port on lines 137–138. Instead of a CIDR like `0.0.0.0/0`, the source is the ALB's security group, so only traffic coming through the ALB is allowed, only on the container port.
- It's attached to the service at lines 331–332 (`SecurityGroups: - !Ref TaskSecurityGroup`).

**Before:** tasks used the default VPC SG (all TCP from `0.0.0.0/0`) with public IPs. **After:** the task is reachable only via its ALB.

## 2. Per-service execution role + separate task role

Two distinct IAM roles instead of one shared one:

- `ExecutionRole` (lines 227–253) — named per-service (line 230), gets the standard managed policy (line 240), and only its own scoped S3-read policy, conditionally (lines 241–253; note line 249 scopes it to that single env file).
- `TaskRole` (lines 257–267) — a separate role, per-service (line 260), deliberately empty (no `Policies` block) = least privilege.
- They're wired in as two different roles on the task definition: line 283 `ExecutionRoleArn: !GetAtt ExecutionRole.Arn` and line 284 `TaskRoleArn: !GetAtt TaskRole.Arn`.

**Before:** one shared `ecsTaskExecutionRole` was both roles for every service, so any container (and its app code) could read every service's config/secrets. **After:** each service has its own execution role (scoped to its own settings) and its own task role.

## 3. Log retention parameter

One parameter, applied to the log group:

- The parameter `LogRetentionDays` is declared at lines 71–75 (default 30).
- It's applied on the log group at line 222: `RetentionInDays: !Ref LogRetentionDays`.

**Before:** log groups had no retention set (kept forever, silent cost growth). **After:** logs auto-expire after N days.

## 4. ECS deployment circuit breaker with auto-rollback

One block on the service that watches deployments:

- In the `Service` resource's `DeploymentConfiguration`, the `DeploymentCircuitBreaker` block at lines 324–326: `Enable: true` (line 325) turns on failure detection, `Rollback: true` (line 326) makes a failed deploy automatically revert to the last good task definition.

**Before:** rollback was the manual 6-step runbook in wiki §9. **After:** ECS does it automatically. (This caught the broken `http-echo` image during testing.)

## 5. Deterministic names

Every resource name is built from the parameters with `!Sub`, so it's predictable and consistent instead of random. For example:

- Cluster: line 100 (`${ServiceName}-cluster-${Environment}`).
- ALB: line 148 (`BeED-${ServiceName}-${Environment}`).
- Target group: line 161, task-def family: line 275, service: line 313, roles: lines 230/260, log group: line 221.
- Plus input validation so bad names can't sneak in: `AllowedPattern` and `MaxLength` on `ServiceName` (lines 22–23) and `AllowedValues` on `Environment` (line 26).

**Before:** console-wizard suffixes like `-wu0ns4py` and typos (`Target-Goup`). **After:** because the target-group name is derived from the same validated `ServiceName`, it's spelled consistently everywhere.
