# Evolving release review

Use this process for a release that exceeds the size limit of the trusted
auto-merge workflow or includes Blender authoring tools under `Scripts/`.
Routine eligible pull requests continue through the existing auto-merge
workflow. [Trusted auto-merge workflow](.github/workflows/codex-automerge.yml)

## Release sign-off

1. **Identify the release and its owner.** The repository owner or a designated
   maintainer records the pull request, target branch, and full head commit SHA.
   The maintainer confirms that an existing repository-approved merge mechanism
   can handle the full scope of the release. If one is unavailable, keep the
   release pending while the repository owner reviews a separate policy or
   configuration proposal.
2. **Review the exact commit.** Record the code review and resolve open findings.
   Review Blender tooling alongside the runtime and bundled assets. Check what
   each authoring script reads and writes, how to reproduce the export, and
   whether generated assets and unrelated content are affected as intended.
3. **Record verification.** Link the passing macOS build and detection checks
   for the head SHA. For a visual release, include the local build, verify, and
   install results, the matched gallery, and the applicable determinism and
   native performance results.
4. **Record maintainer approval.** The repository owner or designated release
   maintainer records approval for that exact SHA in the release PR. If the head
   changes, rerun the required CI and affected local checks, review the new head,
   and refresh sign-off before release.
5. **Verify the landed release.** Use the confirmed release mechanism with
   GitHub branch protections in effect. After it completes, check the merged PR
   and confirm the resulting commit is on the target branch. Record that commit
   before marking the release epic complete.

This document describes sign-off and works within the repository's configured
merge controls. See [AGENTS.md](AGENTS.md) for requirements that apply to
review, CI, and automated fixes.
