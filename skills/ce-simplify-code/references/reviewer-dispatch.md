# Reviewer Dispatch

Read this before dispatching the Step 2 reviewers. It covers what happens when the harness is full, how review agents are released, and the permission mode.

A generic subagent is one whose whole brief is the prompt you send it. When the host's subagent tool makes you name an agent, use only a name you have seen the host list, and list its agents before the first dispatch if you have not. Pick the plain one that adds no role of its own, which still counts as a generic subagent. Never pick a specialist, such as a reviewer or worker agent, whose own role prompt, output format, or tool limits would replace or narrow your prompt.

**Bounded dispatch.** Queue the reviewers and launch only as many as the harness accepts at once. A concurrency or active-agent-limit error means the harness is full, not that the reviewer failed: leave the reviewer queued and retry after a slot frees. When a dispatch cannot recover through active work, supported release, or a corrected invocation, run that pass inline using the same prompt asset and disclose the substitution.

**Agent lifecycle.** Collect terminal outcomes, including failures, before cleanup. Close or release review-owned agents when the harness provides caller-owned cleanup, before refilling slots, advancing stages, or returning. Do not message completed agents with no remaining work. Do not infer released capacity from completion or interruption, or invent cleanup operations.

**Permission mode.** Omit the `mode` parameter on the dispatch call so the user's configured permission settings apply.

**Model role.** A subagent seeded from a prompt asset in `references/personas/` has the role id `ce-simplify-code/<persona>`, where `<persona>` is the asset's file name without `.md` (`code-quality-reviewer`). Before each dispatch, run `python3 ~/.config/agent-routing/resolve.py <harness> <role id>`, where `<harness>` is the tool you are running in (`claude-code`, `grok`, `opencode`, `codex`, `devin` or `muse`), not the one whose instruction file you loaded. A printed model is the model configured for this subagent's role: pass it as the subagent's model and name it in your status note as coming from the routing table. No output, or a failed command, keeps the default above; report any warning once. If the tool rejects the model, dispatch once more with the default and say so.
