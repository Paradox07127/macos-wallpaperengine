# Multica workflow tools

These local helpers poll GitHub on this Mac, route work through the **cloud Multica
workspace** using profile `desktop-api.multica.ai`, and execute through a local
runtime. This is not a self-hosted Multica deployment. The allowed GitHub repository
is `Paradox07127/macos-wallpaperengine`.

## Installed layout and operation

The stable local root is `$HOME/Documents/Codex/Multica`:

| Path beneath the root | Purpose |
| --- | --- |
| `config.json` | Local routing, paths, models and the service `enabled` switch |
| `bridge/` | Installed copies of these helpers and `mmrun-compat` |
| `repository/` | Dedicated Git mirror/checkout used to fetch review targets |
| `state/intake.sqlite3` | Intake checkpoint, mappings and write reconciliation |
| `state/jobs/<job-id>/` | Immutable request and executor/publication receipts |
| `state/reviews/<job-id>/` | Frozen checkout, review manifest and attestation |
| `workspaces/` | Multica daemon workspaces |
| `logs/` | Local service logs |

The LaunchAgent label is `ai.multica.github-bridge`, with its plist at
`~/Library/LaunchAgents/ai.multica.github-bridge.plist`. Its configured cadence is
90 seconds, with `RunAtLoad`; it runs `service.py --config .../config.json` once per
tick. A tick checks the `enabled` switch, ensures the Multica daemon is available,
polls intake once, and collects finished reviews even if that intake poll failed.
Launchd supplies the cadence; running the service is not a precise delivery-time
guarantee. This local path requires a logged-in user session, an awake Mac, network
access and valid GitHub/Multica/model authentication. Check `launchctl` for the live
installation and execution state rather than inferring that the job is running
from this README. Initial provisioning leaves `enabled: false` until activation.

Issue intake uses the `agent-triage` label, with `triage_all_new: false`.

GitHub issue intake is opt-in through the configured label. PR execution is
restricted to non-draft PRs from branches in the allowed repository targeting `main`;
"owner PR" here means a same-repository branch, not an author-login restriction.
Fork PRs must not execute, even if someone adds a label. The controller must validate
repository identity and immutable revisions from GitHub metadata before dispatch. Labels are routing signals,
not authorization for a release or arbitrary external actions. If intake identity or
revision checks fail, leave the job blocked.

### Read-only diagnosis and dry run

The following commands use the installed stable copies. `doctor` checks access;
`poll --once --dry-run` previews intake without updating live checkpoint state,
creating Multica work or writing GitHub statuses. Neither triggers model reviews.

```sh
MULTICA_ROOT="$HOME/Documents/Codex/Multica"
MULTICA_PYTHON=/opt/homebrew/opt/python@3.14/bin/python3.14
MULTICA_CONFIG="$MULTICA_ROOT/config.json"

"$MULTICA_PYTHON" "$MULTICA_ROOT/bridge/github_bridge.py" --config "$MULTICA_CONFIG" doctor
"$MULTICA_PYTHON" "$MULTICA_ROOT/bridge/github_bridge.py" --config "$MULTICA_CONFIG" poll --once --dry-run
launchctl print "gui/$(id -u)/ai.multica.github-bridge"
ls -lt "$MULTICA_ROOT/logs"
```

`executor.py --config "$MULTICA_CONFIG" collect --job-id JOB_ID` revalidates a
specific review and updates its local attestation without publishing a result.
`publish` and `collect-all` are **external write operations**: after verification
they can write GitHub commit statuses and Multica comments/status. Here “publish”
means publishing a static review result, never publishing an application release.
Do not use them as read-only diagnostic commands.

To pause future scheduled ticks, unload the actual installed LaunchAgent:

```sh
launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/ai.multica.github-bridge.plist"
```

Also set `enabled` to `false` in the local config if service ticks should stay
paused after reloading the agent. This switch is checked by `service.py`; it does
not disable deliberate direct `github_bridge.py` or `executor.py` commands.
Unloading the timer does not cancel already running model reviews or stop the
Multica daemon. Inspect those runs separately. For a deliberate restart after
reviewing config, use `launchctl bootstrap "gui/$(id -u)"` with the same plist path.

### mmrun compatibility copy

The original `$HOME/.claude/bin/mmrun` is retained unchanged. A prepared
local copy works around the current Grok JSON transport shape: fresh session ID
per attempt, separate stdout/stderr, and strict structured-result normalization.
It preserves the original provider, tool, permission and sandbox arguments. It
does not turn an error response or incomplete report into approval.

Prepare the copy after placing `mmrun_compat.py` at its stable installed path:

```sh
"$MULTICA_PYTHON" "$MULTICA_ROOT/bridge/mmrun_compat.py" prepare \
  --source "$HOME/.claude/bin/mmrun" \
  --output "$MULTICA_ROOT/bridge/mmrun-compat"
```

`prepare` invokes no model and writes only the separate copy and its
`.provenance.json` sidecar. The installed config must set `mmrun_path` to
`$HOME/Documents/Codex/Multica/bridge/mmrun-compat`; the executor passes
that value as `review_runner.py run --mmrun ...`. A direct runner invocation must
also explicitly pass `--mmrun` because its default remains the original installed
script. With a redirected `CODEX_HOME`, pass the configured real profile home as
`--codex-home $HOME/.codex` as well.

The runner verifies the copy, source and helper hashes against the provenance
sidecar. If the original script or compatibility helper changes, prepare a newly
reviewed copy. Changed patch anchors fail closed; a destination containing different
content is not overwritten. Choose a new output filename, verify its provenance,
then update `mmrun_path` deliberately. Do not delete evidence or overwrite the
original mmrun to make a failed preparation pass.

## Release candidate review: dry run first

Release intake is manual via `request-release`. It creates a static-review job
bound to explicit full base/head commits and a version. It does not tag, package,
upload or publish a release. Replace all placeholders in this **disabled example**
with maintainer-selected values before use:

```text
"$MULTICA_PYTHON" "$MULTICA_ROOT/bridge/github_bridge.py" --config "$MULTICA_CONFIG" \
  request-release --base FULL_40_CHARACTER_BASE_COMMIT \
  --head FULL_40_CHARACTER_REVIEWED_HEAD_COMMIT --version MAJOR.MINOR.PATCH --dry-run
```

Only remove `--dry-run` when intentionally dispatching the candidate review. Inspect
the corresponding `state/jobs/<job-id>/request.json`, then collect its attestation.
Do not infer success from a task having started or from a model's `DONE` status.
After a verified release-kind PASS, use the gate below. No timer or example here
enables automatic application publication.

## Static release-review evidence check

`release_gate.py` uses only Python's standard library and Git. It has two actions:

- `check`: validate the recorded static release review against the requested Git
  revisions and the current clean checkout.
- `plan`: perform the same checks and print a command for the existing
  `scripts/release-app.sh`, with only `--sku` and `--version` arguments.

Neither action runs packaging, signs or notarizes software, modifies an appcast,
creates a tag, or publishes a GitHub release. There is no `publish` action, arbitrary
argument passthrough, `--skip-checks`, or `--dry-run` escape hatch in the gate. The
existing release script's `--dry-run` skips release-candidate checks and therefore is
not evidence of a verified release. The gate leaves that script unchanged.

The following are **disabled examples**, not commands to run until real, verified
values replace every placeholder:

```text
"$MULTICA_PYTHON" "$MULTICA_ROOT/bridge/release_gate.py" check \
  --repo "$MULTICA_ROOT/state/reviews/RELEASE_JOB_ID/frozen" \
  --attestation "$MULTICA_ROOT/state/reviews/RELEASE_JOB_ID/attestation.json" \
  --base-sha FULL_40_CHARACTER_BASE_COMMIT \
  --head-sha FULL_40_CHARACTER_REVIEWED_HEAD_COMMIT

"$MULTICA_PYTHON" "$MULTICA_ROOT/bridge/release_gate.py" plan \
  --repo "$MULTICA_ROOT/state/reviews/RELEASE_JOB_ID/frozen" \
  --attestation "$MULTICA_ROOT/state/reviews/RELEASE_JOB_ID/attestation.json" \
  --base-sha FULL_40_CHARACTER_BASE_COMMIT \
  --head-sha FULL_40_CHARACTER_REVIEWED_HEAD_COMMIT \
  --sku pro --version MAJOR.MINOR.PATCH
```

The expected base and head must come from the maintainer's release candidate decision,
not be silently copied from an arbitrary attestation. Both are full lowercase Git
SHA-1 commit IDs. HEAD must equal the reviewed head; the base must exist and be its
ancestor; the current tree ID must equal the reviewed tree. Staged, unstaged,
untracked and dirty submodule changes block the check. Store evidence outside the
checkout, or in an intentionally ignored evidence directory, so it does not itself
make the tree dirty.

`review_runner` supplies a JSON attestation with `schema_version: 1`, `kind: release`,
`verdict: PASS`, the canonical frozen checkout as `repo`, the input checkout as
`source_repo`, `base_sha`, `head_sha`, `tree_sha`,
`policy`, an absolute `artifact_root`, and a nonempty `artifacts` list. Each artifact
has a relative `path` and full lowercase `sha256`. The gate rejects escaping paths,
symlinks, missing files, duplicate records and changed hashes. Raw model logs are not
required for this manifest; structured reports, status, metadata and output evidence
are required by the review policy. Preserve those files together with the attestation.
Pass the frozen checkout as `--repo`. The gate reuses `review_runner`'s strict report
schema validator and requires its versioned full-tree-and-base-delta release policy.
Both Codex and Grok must participate; an optional `agy` review must also pass if listed.
Each listed model needs hashed `.json`, `.out`, `.status` and `.meta` evidence,
`DONE` status, exactly one `exit=0`, an `approve` verdict, no critical/major findings
and zero `not_expanded` findings. A top-level `PASS` alone never satisfies the gate.

Success is explicitly reported as `STATIC_REVIEW_VERIFIED`, **not release approval**.
A JSON file and matching hashes are integrity checks relative to that file, not a
cryptographic signature or proof of trusted authorship. Anyone able to modify both
the attestation and its artifacts can forge matching evidence. The gate is a helper,
not an enforced repository-wide or platform permission boundary, and a clean Git
status does not inventory ignored files or the build host environment.

## Human release handoff

After checking the provenance and scope of the static review, the maintainer must
run the existing release checks and packaging, inspect the resulting archive/app/DMG
and signatures, archive the evidence, verify the actual distribution asset hashes,
and approve final publication separately. Review-artifact hashes do not authenticate
a future DMG. Packaging may change generated appcasts and other outputs; run the
appropriate existing release-contract checks for that state and retain the results.

The runner deliberately makes its frozen checkout read-only. Preserve that evidence
checkout; do not make it writable to build there. The current `plan` prints a command
under the checked frozen path as a preview, not a ready-to-run build location. For
actual packaging, use a separate clean, writable release checkout at the same
reviewed head and run its existing `scripts/release-app.sh --sku ... --version ...`.
Verify and archive that checkout's HEAD and build evidence separately. Neither this
static attestation nor the gate currently binds a future package's version, signing
identity or distribution bytes; the release script and human asset validation must
establish those facts.

Re-run the gate if HEAD, the base selection, reviewed artifacts or checkout changes.
There is no transaction or filesystem lock spanning this check and a later manual
build; check immediately before use and ensure no other writer is working there.
The printed plan is only a proposal and does not turn a stale attestation into a
valid release. Automated publication and a complete hard release gate are not
implemented here.

## Tests

```sh
python3 -m unittest discover -s tests -p 'test_release_gate.py'
```

Tests create disposable Git repositories and evidence files. They do not build the
app, invoke the real release script, publish, or commit changes in this repository.
