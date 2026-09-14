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
| `state/reviews/<job-id>/` | Frozen checkout, review manifest and model evidence |
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

### Feedback intake and safe Triage

Keep `triage_all_new: false` for normal operation. A maintainer adds `agent-triage`
when a report is ready for an initial assessment. That label is an explicit intake
decision: the maintainer still judges whether the report belongs to this project.
It does not authorize running commands from the report, fetching attachments or
publishing anything.

Configure the **cloud Triage agent**, identified by `triage_agent_id`, separately
from Review Coordinator. For its Claude Code runtime, disable tools with
`--tools ''`, use strict MCP configuration with an empty MCP server set, and enable
Multica Safe Mode. Verify the effective runtime configuration after changing the
agent. These settings belong to the cloud agent; editing local `config.json`
alone does not apply them. Tools-disabled operation is not an operating-system
sandbox, and Review Coordinator's executor access must not be given to Triage.

The initial intake creates an unassigned Backlog issue, assigns Triage using
`--no-start`, and then sends exactly one explicit mention carrying the bounded
title, body and recent public comments. This supplies the information a
tools-disabled agent needs without requiring `issue get`. It keeps public author
logins, bot flags and original links, but does not read profile email fields or
download the linked attachments. Triage should distinguish evidence, prior
answers and missing information in its response.

Later issue edits and ordinary comments are **data updates only**. The bridge
starts those Multica comments with `/note`, which suppresses the platform's
assignee fallback. Simply omitting an `@mention` is insufficient. Unrelated
discussion or an injected instruction therefore does not automatically launch
another investigation. Bot comments are ignored.

A maintainer can request a follow-up by posting this complete line on the
original GitHub issue:

```text
/multica-triage
```

The bridge ignores the command inside a Markdown quote, fenced/indented code or
additional text on the same line. It verifies the comment author's **current**
repository permission through GitHub's collaborator-permission API; only
`write`, `maintain` or `admin` qualifies. A claimed role in the body or
`author_association` does not authorize a run. The resulting agent trigger contains
a fresh API snapshot of the issue and bounded recent comments, with a fixed
bridge instruction; it does not promote the external command body into a tool
instruction. Reports and follow-up questions stay in Multica. No GitHub reply or
external message is sent by this intake bridge.

| Local setting | Default | Effect |
| --- | --- | --- |
| `triage_label` | `agent-triage` | Opt-in initial intake |
| `triage_all_new` | `false` | Avoid automatically admitting all new reports |
| `max_body_chars` | `12000` | Hard limit for an external body; commands beyond it do not execute |
| `max_history_comments` | `20` | Maximum recent comments in a snapshot |
| `max_history_chars` | `20000` | Combined JSON text budget for those comments |
| `triage_cooldown_seconds` | `600` | Per-issue interval between follow-up delivery attempts |
| `max_triage_followups_per_tick` | `3` | Follow-up delivery attempts per service tick |

The follow-up limits do **not** count initial label-approved intake or PR review.
Uncertain deliveries count as attempts, so a lost acknowledgement cannot evade
the limits. Deferred follow-ups remain in SQLite and are retried on later ticks,
including ticks without new GitHub activity. A permission 404 or insufficient
permission becomes an observable `denied` record; transient API failures remain
`pending`. After fixing a denied request's permission, post a new explicit request.
`doctor` prints the queue totals. For individual reasons, inspect the local state
read-only:

```sh
sqlite3 -readonly "$HOME/Documents/Codex/Multica/state/intake.sqlite3" \
  'SELECT status, reason, COUNT(*) FROM triage_pending GROUP BY status, reason;'
```

### Review status names

The bridge writes only pending statuses; the trusted collector validates the
versioned policy and attestation before publishing a result. Status contexts are
scoped to the work being reviewed:

- PR: `multica/review/pr-<number>`.
- Release candidate: `multica/release/<job_id>`.

This keeps two PRs or release candidates at the same commit from overwriting each
other's status. Use the request manifest's revisions and the installed runner's
policy/evidence paths when collecting. Existing statuses under older shared names
are historical and must not be treated as approval for a new candidate. These
helpers do not themselves install a GitHub branch-protection rule or grant final
release approval.

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
  --attestation ABSOLUTE_ATTESTATION_PATH_FROM_VERIFIED_EXECUTOR_RECEIPT \
  --base-sha FULL_40_CHARACTER_BASE_COMMIT \
  --head-sha FULL_40_CHARACTER_REVIEWED_HEAD_COMMIT

"$MULTICA_PYTHON" "$MULTICA_ROOT/bridge/release_gate.py" plan \
  --repo "$MULTICA_ROOT/state/reviews/RELEASE_JOB_ID/frozen" \
  --attestation ABSOLUTE_ATTESTATION_PATH_FROM_VERIFIED_EXECUTOR_RECEIPT \
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

Use the attestation location reported by the verified executor receipt, not a
similarly named file supplied by a model or copied from an older run. `review_runner`
supplies a JSON attestation with its supported `schema_version`, `kind: release`,
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
python3 -m unittest discover -s tests -p 'test_github_bridge.py'
python3 -m unittest discover -s tests -p 'test_multica_service.py'
python3 -m unittest discover -s tests -p 'test_release_gate.py'
```

Bridge and service tests mock the CLIs, network and daemon operations. Gate tests
create disposable Git repositories and evidence files. They do not build the app,
invoke the real release script, publish, or commit changes in this repository.

## Explicit retry after a failed review

A repeated `run` collects the existing attempt; it never silently starts another
paid model run. After inspecting an actual `FAILED` or `NEEDS_REVIEW` result, an
operator can explicitly request a new attempt:

```text
python3 "$MULTICA_ROOT/bridge/executor.py" --config "$MULTICA_ROOT/config.json" \
  retry --job-id LOGICAL_JOB_ID
```

Retry checks the current GitHub target and refuses passed, live, busy, unknown or
superseded work. Earlier frozen checkouts, complete reports and receipts remain
intact. `attempt.json` selects the new runner ID; subsequent collect/publish calls
still use the same logical job ID. No automatic retry loop is enabled.
