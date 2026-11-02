# Releasing

Versions are computed by [semantic-release](https://semantic-release.gitbook.io/) from
conventional commits, land on `main` through a release PR, and are published to
[pub.dev](https://pub.dev/packages/suqo_checkout) as `suqo_checkout`. Two workflows do it:

- `.github/workflows/release.yml` (every push to `main`): tags the merged release and keeps the
  release PR up to date.
- `.github/workflows/publish.yml` (every `vX.Y.Z` tag): re-runs the checks, creates the GitHub
  Release and publishes to pub.dev.

Their header comments have the details.

## Commit messages decide the version

| Commit                                        | Bump                  |
| --------------------------------------------- | --------------------- |
| `fix: …`                                      | patch (0.1.0 → 0.1.1) |
| `feat: …`                                     | minor (0.1.0 → 0.2.0) |
| `feat!: …`, or a `BREAKING CHANGE:` footer    | major (0.1.0 → 1.0.0) |
| `docs:`, `chore:`, `test:`, `refactor:`, etc. | no release            |

A breaking change goes straight to 1.0.0, even while the version is below 1.0. Commits are parsed
with the [Conventional Commits](https://www.conventionalcommits.org/) preset (`.releaserc.json`).

## Every release

1. Merge PRs into `main` as usual.
2. The Release workflow opens (or updates) a `bump-release/vX.Y.Z` PR that bumps the version in
   `pubspec.yaml` and `suqoCheckoutVersion` in `lib/suqo_checkout.dart`, and adds the new
   `CHANGELOG.md` section.
3. That PR doesn't start CI by itself, because it was opened with `GITHUB_TOKEN`. Push an empty
   commit to it, or close and reopen it, then merge once it's green. Later merges to `main` leave
   the PR's branch alone unless the release itself changes (its version, or its notes after a new
   `feat:`/`fix:`), so your nudge isn't wiped by an unrelated merge. When it does change, nudge
   again.
4. The merge tags `vX.Y.Z` on the merge commit and starts the Publish workflow on that tag. Once
   its checks pass, the "Publish to pub.dev" job waits for approval: open the run, click **Review deployments**, tick `pub.dev` and approve. The version
   is live on pub.dev as soon as that job finishes. There's no staging step after it.

## If a publish fails

Use **"Re-run failed jobs"** on the Publish run for that tag. Each job checks what already exists
(the GitHub Release, the version on pub.dev) and only does what's missing. Don't delete the tag to
retry.

If there's no Publish run for the tag (the Release run's "Start publish" job failed), re-run that
Release run's failed jobs. Only the run that created the tag starts a publish, so pushing more
commits to `main` won't. Or start it by hand: Actions → Publish → **Run workflow**, and pick the
`vX.Y.Z` tag (not a branch) under "Use workflow from".

If the tag itself is missing (the Release run failed before tagging), re-run that Release run, or
merge anything into `main`. The next run tags the commit that set the version, not `HEAD`.

## A version can't be unpublished

pub.dev never deletes a version. Within 7 days of publishing, a version can be **retracted** from
the package's Admin tab, which hides it from resolution but keeps it downloadable for anyone who
already depends on it. Fix forward with a new `fix:` release instead.

## Never bump the version by hand

The release PR is the only thing that should change the version. `scripts/set-version.mjs` keeps
`pubspec.yaml` and `suqoCheckoutVersion` equal, and `test/version_test.dart` fails CI if they ever
disagree.

## Local checks

Run `git config core.hooksPath hooks` once per clone. `hooks/pre-push` then runs format, analyze
and test before every push, and blocks pushes straight to `main`.

## Tool versions

`release.yml` pins semantic-release (`SEMANTIC_RELEASE_PACKAGES`) on purpose: that job holds a
write token. Bump it deliberately. semantic-release isn't a dependency of this package (there's no
`package.json`); the job installs it for itself. Keep `conventional-changelog-conventionalcommits` on
the major that matches the plugins' conventional-changelog libraries (9.x for the current pins).

## One-time setup

No GitHub App or secrets are needed: everything runs on `GITHUB_TOKEN`. If the repo has a ruleset
that restricts creating `v*` tags, add **GitHub Actions** to its bypass list, since `release.yml`
pushes them.

### 1. `pub.dev` environment

In Settings → Environments, create an environment named exactly `pub.dev`. Add required reviewers
(the people who may approve a publish), and under deployment branches and tags, allow only tags
matching `v*.*.*`.

### 2. First publish: 0.1.0, by hand

pub.dev only lets you turn on automated publishing for a package that already exists, so the first
version is published from your own account. Do it from `main` **before** merging the PR that adds
these workflows, so the tag lands on the commit that was actually published.

1. With `main` checked out and `pubspec.yaml` at `0.1.0`, run `flutter pub publish --dry-run`. The
   only warning should be pub's layout check asking to rename `docs/` to `doc/`: that rename lands
   in the workflows PR, after this publish. Any other warning, fix it first.
2. `flutter pub publish`. The first time, it opens a browser to sign in with the Google account
   that will own the package.
3. Tag what you just published and push the tag:
   `git tag -a v0.1.0 -m v0.1.0 && git push origin v0.1.0`. (That commit has no `publish.yml`, so
   nothing runs. Create the v0.1.0 GitHub Release by hand if you want one.)

### 3. Verified publisher (recommended)

Move the package from a personal account to the `suqo.ai` publisher, so pub.dev shows it as
published by SUQO, not by a person:

1. On https://pub.dev/create-publisher, create `suqo.ai`. It asks you to verify the domain in
   Google Search Console (a DNS TXT record) with the same Google account.
2. On the package's Admin tab, **Transfer to publisher** → `suqo.ai`. Add the other maintainers as
   publisher members.

### 4. Turn on automated publishing

On https://pub.dev/packages/suqo_checkout/admin, under **Automated publishing**:

- **Enable publishing from GitHub Actions**, repository `suqo-ai/suqo-flutter`.
- **Tag pattern:** `v{{version}}`.
- **Require GitHub Actions environment:** `pub.dev`.
- **Enable publishing from `workflow_dispatch` events:** on. `release.yml` pushes the tag with
  `GITHUB_TOKEN`, which can't start `publish.yml` by itself, so it dispatches `publish.yml` on the
  tag instead. pub.dev still checks that the run's ref is a tag matching the pattern, so a dispatch
  on a branch can't publish. Leave publishing from `push` events on too, for a tag pushed by hand.

### 5. Merge the workflows

**Squash-merge** the PR that adds these workflows, keeping its `ci:` title. It contains a `fix:`
commit (the `docs/` → `doc/` rename), and a merge commit or rebase would put that on `main` as a
releasable change, opening a 0.1.1 release PR for tooling alone. Squashed, the Release run sees
`v0.1.0` already on the remote and nothing releasable since. From then on, the first `feat:` or
`fix:` that lands opens the next release PR.
