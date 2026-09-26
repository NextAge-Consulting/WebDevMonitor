# CLI Utilities

Discipline for command-line tools targeting a specific account, region or project, where hitting the wrong one is expensive and usually silent.

## AWS CLI

### `/deploy` needs NO personal AWS session — never pre-check one for it

**`deploy.sh` authenticates itself.** Under `DEPLOY_BACKEND=codebuild` it reads
`DEPLOY_AWS_ACCESS_KEY_ID` / `DEPLOY_AWS_SECRET_ACCESS_KEY` from `.env` and
exports them, deliberately bypassing `AWS_PROFILE` and the hub-and-role chain.
That key is scoped to `codebuild:StartBuild` and `BatchGetBuilds` on the named
project ARNs and nothing else. It also validates itself as a state gate, before
the bump, and exits 21 with instructions if it is missing or revoked.

So running `aws sts get-caller-identity --profile <personal>` before `/deploy`
checks a credential the deploy will never use. When that personal session
happens to be expired — and on a hub-and-role setup it expires **hourly**, a
hard AWS limit on chained roles that no setting can raise — the check stops a
deploy that would have worked, and sends the human through a browser login for
nothing. Every deploy. That is the failure this rule exists to prevent, so it
is worth stating as its own carve-out rather than as a footnote to the rule
below.

**Check a personal session only for work that actually uses the personal
profile** — Parameter Store, Secrets Manager, EC2, SSM, IAM, ad-hoc
investigation. Not for `/deploy`, and not for any other command that carries
its own credential.

### Check the session before the task, not when a command fails (Zero Tolerance)

Applies to work using the PERSONAL profile. See the carve-out above first — a
command with its own credential is not this case.

The moment a task will touch AWS at all:

```bash
PROFILE=$(jq -r .AWS_PROFILE .claude/sync-substitutions.json)
REGION=$(jq -r .AWS_REGION  .claude/sync-substitutions.json)
aws sts get-caller-identity --profile "$PROFILE" --region "$REGION"
```

Check that the `Account` it returns equals `AWS_ACCOUNT_ID` from the same file before any operation that reads or writes. If the command fails, **stop and ask the human to run `! aws login --profile <name>`** — the leading `!` is what they type in the Claude Code prompt to run it in this session, so paste it with the bang. Sessions expire between working sessions, so this is the normal first step of an AWS task rather than an exception.

**With an expired session, stop — never substitute a guess.** "The repository presumably exists", "that's probably configured", "it's likely still set to X", written into code, docs or a report as though verified, is worse than the delay it avoids: an unverified claim stated confidently is indistinguishable from a checked one.

| Forbidden | Instead |
|-----------|---------|
| "AWS isn't available, so I'll assume X" | Stop. Ask for `aws login`. |
| Writing an unverified claim into a doc, spec or report | Don't write it — or mark it explicitly unverified **and** say so in the reply |
| Discovering the expired session three commands into a task | Check `get-caller-identity` before starting |
| Handing the human a command *you* could run once authenticated | Ask for the login, then run it yourself |
| Doing adjacent or prep work while waiting for the login | Stop. The login request is the entire reply. |

**Stop the whole turn, not just the AWS command.** An expired session blocks the
task, so the reply is the login request and nothing else. Do not keep working around
it — not adjacent prep, not "everything that doesn't need AWS yet", not reading the
files you would have checked afterwards. That work is built on facts you have not
established, so it gets redone or discarded the moment the answer arrives, and it
buries the one line the human has to act on under output they cannot use.

If the human declines to authenticate, say plainly which specific facts are therefore unknown, and leave the gap open.

### Always explicit

Pass `--region` and `--profile` on every command, and never rely on the shell's default. Never run `aws configure set` **without** `--profile` to make a command work — that repoints every later command silently. Scoped to a named profile it is fine, which is why the region-setting step below is allowed.

This project's target values live in `.claude/sync-substitutions.json`, relative to the repo root, as `AWS_ACCOUNT_ID`, `AWS_REGION` and `AWS_PROFILE`. Read them and use those exact values; they differ per project, across several accounts and regions.

### Profile provisioning

**Resolve the profile's shape before touching it — never assume which pattern is in
play.** `AWS_PROFILE` in `sync-substitutions.json` names the profile *this project*
authenticates through; how that profile itself is set up is a per-developer, per-machine
choice, not something this file can hardcode. Check it:

```bash
aws configure get source_profile --profile "$PROFILE" 2>/dev/null
```

Empty means the default case below. A name means the hub-and-role case — and that name
*is* the hub, resolved just now rather than assumed.

**Default: a single account, one profile, nothing chained.** Most developers, and most
clients running their own AI-assisted AWS work, have exactly one AWS account. `AWS_PROFILE`
names a plain profile with its own credentials or its own login flow — authenticate it the
way it was set up (`aws login --profile <name>`, `aws sso login --profile <name>`, or
whatever that profile uses), same as any other AWS CLI session. Nothing else in this
section applies.

**Optional: one person's hub, reaching several accounts by role assumption.** For someone
who works across multiple AWS accounts from one machine (a consultant with several
clients, say) and does not want to sign in and out of each one, a personal hub profile can
assume a scoped role into every other account instead:

```
[profile <hub>]
login_session = arn:aws:iam::<hub-account>:user/<iam-user>
region = <hub-region>

[profile <client>]
role_arn = arn:aws:iam::<client-account>:role/<OperatorRoleName>
source_profile = <hub>
region = <their-region>
```

This is a personal setup choice, not a project requirement — a client adopting AI-assisted
AWS work in their own account has no reason to build this, and nothing here should suggest
they need to. Where it IS in use:

A client role's trust policy names the hub account and nothing else — one statement, no
conditions. Anything carried in the profile ALONGSIDE the role is a second way for the
chain to break, and the console's Switch Role form cannot send one at all, so a condition
there costs console access to every client account.

A client profile that reports an expired session is fixed by logging into **the hub**
(resolved above), not that profile. The CLI calls STS itself, caches the temporary
credentials under `~/.aws/cli/cache`, and refreshes them without asking.

**NEVER run `aws login` against a client (role-assumption) profile — the hub is the ONLY
profile anyone ever logs into.** Confirm which is which with the `source_profile` check
above before handing over any login command — a profile with a `role_arn` is a client, a
profile with a `login_session` is a hub, and guessing from the profile's name is exactly
how this goes wrong on a machine you didn't set up.

**Logging into a client profile CORRUPTS it.** `aws login --profile <client>` appends a
`login_session` line to a profile that only ever meant to assume a role. That line then
shadows the role chain and every command fails with:

```
ValidationException ... CreateOAuth2Token ... The provided authorization grant is
invalid, expired, revoked, or malformed
```

which reads as an expired session — so the natural response is to log in again, which
rewrites the line and breaks it again. Recognise the loop by the error naming
`CreateOAuth2Token` on a profile that has a `role_arn`.

**Recovery:** delete that one `login_session` line from the client profile in
`~/.aws/config`, then `aws login --profile <hub>`. Nothing else needs touching; the
client profile works again immediately. Do NOT sign out of the browser or clear
cookies for this — that is the fix for the 400 below, a different failure.

**A profile with no region cannot be logged into — set the region first.** `aws login`
prompts for one, and from the Claude Code prompt there is no terminal to prompt on, so it
dies with `Warning: Input is not a terminal` followed by `[Errno 22] Invalid argument`.
That failure names neither the profile nor the region, so it reads as a broken install. On
a machine whose `~/.aws/config` has no entry for this profile yet, hand over both lines
together:

```bash
aws configure set region <region> --profile <name>
aws login --profile <name>
```

**The human runs `aws login --profile <hub>`** (the name resolved above) — hand them
`! aws login --profile <hub>` and wait. It is a browser console sign-in that writes a
`login_session` line and manages temporary credentials with a refresh token, so no static
keys land on disk. Invoked from a tool call it blocks until it times out, having
accomplished nothing.

One profile per AWS account, named for the account or client, not per project. Projects
sharing an account share the profile, and each still records it in its own `AWS_PROFILE`
value.

Never create a profile via `aws configure` with static access keys, and never promote app
runtime keys from `.env` into a CLI profile — those are scoped for the app, not for CLI
work. This is about *personal, interactive* AWS work; a project's own recurring automated
task (its deploy trigger, say) is a different problem with a different answer — a
narrowly-scoped, long-lived credential created directly in that project's own account, with
no relationship to any hub. See the project's own deploy/infra setup docs for that case;
it has nothing to do with which AWS profile a developer authenticates with.

### 400 Bad Request from `aws login`

**Fix it by signing into the AWS console in the default browser first, then running `aws login --profile <hub>`.** Sign the browser in **as the account being authenticated** — a console session for a different account is what produces the 400, which is why the hub-and-role shape above avoids this entirely: there is only ever one account to sign into. Signing out and clearing cookies for `signin.aws.amazon.com` also works; an incognito window does not reliably, because the flow wants an established session.

The symptom is a bare 400 at `https://<region>.signin.aws.amazon.com/oauth?…&client_id=arn:aws:signin:::devtools/same-device&…` while the CLI hangs for minutes on a loopback callback that never fires. The cause is stale or absent browser session cookies — not a credential, region or profile problem. Nothing in `~/.aws/` is wrong, so don't go hunting there; the 400 happens before anything reaches the token cache.

Upstream: https://github.com/aws/aws-cli/issues/10186
