# Phase 5b Compatibility Spike Test Protocol

## Objective

Validate whether the preferred Phase 5b provider candidate can satisfy the requirements of ADR-0009 Revision B.

This spike validates:

```text
Litmus 2.8.2
+
Vagrant
+
VirtualBox
+
Dedicated Validation Host
```

It does not validate:

```text
EC2
libvirt/KVM
Windows
BSD
Solaris
multi-target execution
multi-provider execution
```

## Success Criteria

The spike is successful if all of the following can be demonstrated:

- VM provisioning succeeds.
- Litmus can communicate with the target.
- Puppet apply succeeds.
- Acceptance assertions succeed.
- VM destruction succeeds.
- Resource cleanup is verified.
- Per-run SSH credentials are removed.
- Controller/worker separation remains intact.
- No provider credentials are exposed to acceptance execution.

## Test Environment

### Controller

Dedicated validation host only.

Requirements:

- Ubuntu 24.04
- Vagrant (pinned version)
- VirtualBox (pinned version)
- Litmus 2.8.2
- No AgentForge workstation profile involvement

### Worker

Acceptance execution worker.

Requirements:

- No provider credentials
- No VirtualBox API access
- No controller filesystem access

### Target

One Linux VM only.

Initial candidate:

```text
Ubuntu 22.04 LTS
```

Alternative:

```text
Rocky Linux 9
```

Only one target may be active during the spike.

## Version Validation

Record:

```bash
vagrant version
VBoxManage --version
bundle exec litmus --version
ruby --version
```

Capture results in:

```text
phase5b-compatibility-report.md
```

## Test 1 – VM Provisioning

### Goal

Validate VM creation through Vagrant.

### Procedure

Create the VM using Litmus provisioning.

Record:

- Vagrant version
- VirtualBox version
- Box identifier
- VM identifier

### Success Criteria

- VM created successfully.
- VM reachable via SSH.
- No provisioning warnings requiring manual intervention.

### Failure Criteria

- VM cannot be created.
- VM cannot be reached.
- Manual repair is required.

## Test 2 – SSH Lifecycle

### Goal

Validate per-run credential handling.

### Procedure

Inspect:

- generated SSH keys
- key permissions
- key locations

Record:

- creation time
- ownership
- permissions

After cleanup verify removal.

### Success Criteria

- Dedicated run-scoped keys created.
- Keys not reused from previous runs.
- Keys removed after cleanup.

## Test 3 – Puppet Apply

### Goal

Validate Puppet execution inside the VM.

### Procedure

Run a minimal Litmus acceptance test.

Example:

```puppet
notify { 'phase5b-test':
  message => 'Phase 5b validation';
}
```

### Success Criteria

- Puppet apply exits successfully.
- Expected resource is applied.

## Test 4 – Acceptance Assertion

### Goal

Validate Litmus assertions.

### Procedure

Execute one acceptance assertion.

Examples:

```ruby
describe package('bash') do
  it { is_expected.to be_installed }
end
```

or

```ruby
describe file('/tmp') do
  it { is_expected.to exist }
end
```

### Success Criteria

- Assertion passes.
- Litmus reports success.

## Test 5 – Cleanup

### Goal

Validate normal cleanup behavior.

### Procedure

Destroy VM.

Verify:

- Vagrant inventory
- VirtualBox inventory

### Success Criteria

- VM removed.
- VM disks removed.
- VM networking removed.

## Test 6 – Interrupted Run Recovery

### Goal

Validate cleanup after interruption.

### Procedure

Interrupt execution during:

- provisioning
or
- acceptance execution

Simulate:

```bash
SIGTERM
```

or controller process termination.

### Verify

- orphan detection
- cleanup reconciliation
- inventory reconciliation

### Success Criteria

- All resources recovered.
- No orphan VM remains.
- No orphan disk remains.

## Test 7 – Resource Reconciliation

### Goal

Validate ADR-0009 cleanup requirements.

### Procedure

Compare:

#### Journal

```text
Run ID
VM ID
Disk ID
Network ID
```

Against:

#### VirtualBox Inventory

```bash
VBoxManage list vms
VBoxManage list hdds
VBoxManage list natnets
```

### Success Criteria

- Journal matches provider inventory.
- No unexpected resources remain.

## Test 8 – Security Boundary Validation

### Goal

Validate controller/worker isolation.

### Verify Worker Cannot Access:

- VirtualBox APIs
- Controller files
- Controller journals
- Controller credentials

### Verify Controller Holds:

- Provisioning authority
- Resource inventory
- Cleanup authority

### Success Criteria

- Worker isolation maintained.
- No controller credential exposure.

## Test 9 – Cost and Runtime Controls

### Goal

Validate ADR-0009 bounded-resource requirements.

### Configuration

Maximum:

```text
1 active run
1 VM
1 hours runtime
```

### Verify

- limit enforcement
- timeout handling
- automatic termination

### Success Criteria

- Limits enforced.
- Timeout cleanup succeeds.

## Deliverables

Produce:

### Compatibility Findings

- Litmus compatibility
- Vagrant compatibility
- VirtualBox compatibility

### Security Findings

- credential handling
- controller isolation
- worker isolation

### Cleanup Findings

- normal cleanup
- interrupted cleanup
- reconciliation results

### Operational Findings

- setup effort
- troubleshooting effort
- maintenance concerns

### Recommendation

Choose one:

#### A

```text
Proceed with Vagrant + VirtualBox implementation.
```

#### B

```text
Switch to Vagrant + libvirt/KVM.
```

#### C

```text
Phase 5b not currently viable.
```

## Exit Criteria

The spike is complete when:

- All tests have executed.
- Findings are documented.
- Final recommendation has been recorded.
- ADR-0009 can be updated based on evidence rather than assumptions.
