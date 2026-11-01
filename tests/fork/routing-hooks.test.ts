import { readdir, readFile } from "fs/promises"
import path from "path"
import { describe, expect, test } from "bun:test"

/**
 * Fork-only: every place that dispatches a native subagent carries one
 * "Model role." paragraph that names a role id and tells the agent to look it
 * up in the personal routing table (~/.config/agent-routing, kept in
 * lennartorlando/agent-config). fork/roles.txt lists every concrete role id so
 * the table can be checked for typos; this test keeps the hooks and that list
 * in lockstep, and pins each hook right after upstream's precedence sentence
 * where that sentence exists, so a clean rebase cannot silently strand it.
 */
const repoRoot = process.cwd()

const PRECEDENCE_SENTENCE =
  "Without such an instruction, a model configured for this subagent's role takes precedence over the default tier."

const HOOK_MARKER = "**Model role.**"
const LOOKUP_COMMAND = "python3 ~/.config/agent-routing/resolve.py <harness> <role id>"

// Files whose hook sits directly after upstream's precedence sentence.
const AFTER_PRECEDENCE = [
  "skills/ce-brainstorm/references/model-tiers.md",
  "skills/ce-code-review/references/dispatch-reviewers.md",
  "skills/ce-code-review/references/finish-input.md",
  "skills/ce-code-review/references/scope.md",
  "skills/ce-compound/references/grounding-validation.md",
  "skills/ce-doc-review/references/dispatch.md",
  "skills/ce-explain/references/orchestration.md",
  "skills/ce-ideate/references/grounding.md",
  "skills/ce-plan/references/research.md",
  "skills/ce-plan/references/universal-planning.md",
  "skills/ce-pov/references/grounding.md",
  "skills/ce-sweep/references/model-tiers.md",
]

// A SKILL.md with no byte room for the hook (Codex's 8000-byte prompt bound):
// it already sends the agent to the reference that carries the hook before dispatching.
const POINTED: Record<string, string> = {
  "skills/ce-simplify-code/SKILL.md": "skills/ce-simplify-code/references/reviewer-dispatch.md",
}

// Files whose dispatch has no tier text, so the hook carries the user-named-model rule itself.
const STANDALONE = [
  "skills/ce-bakeoff/references/candidates.md",
  "skills/ce-bakeoff/references/judging.md",
  "skills/ce-compound-refresh/references/investigate.md",
  "skills/ce-compound-refresh/references/per-action-flows.md",
  "skills/ce-compound/references/enhancement.md",
  "skills/ce-compound/references/research.md",
  "skills/ce-compound/references/session-history.md",
  "skills/ce-debug/references/investigate.md",
  "skills/ce-optimize/references/loop.md",
  "skills/ce-optimize/references/measurement.md",
  "skills/ce-plan/references/deepening-workflow.md",
  "skills/ce-prototype/references/scoping.md",
  "skills/ce-resolve-pr-feedback/references/full-mode.md",
  "skills/ce-retune/references/corpus-audit.md",
  "skills/ce-retune/references/cut-passes.md",
  "skills/ce-work/references/execution-strategy.md",
  "skills/ce-work/references/implementation-loop.md",
  "skills/ce-work/references/review-findings-followup.md",
]

const HOOK_FILES = [...AFTER_PRECEDENCE, ...Object.values(POINTED), ...STANDALONE].sort()

function paragraphs(markdown: string): string[] {
  return markdown
    .replace(/```[\s\S]*?```/g, "")
    .split(/\n\s*\n/)
    .map((p) => p.trim())
    .filter(Boolean)
}

async function markdownFiles(root: string): Promise<string[]> {
  const entries = await readdir(root, { withFileTypes: true })
  const nested = await Promise.all(
    entries.map(async (entry) => {
      const absolute = path.join(root, entry.name)
      if (entry.isDirectory()) return markdownFiles(absolute)
      return entry.isFile() && entry.name.endsWith(".md") ? [absolute] : []
    }),
  )
  return nested.flat()
}

async function hookParagraphs(relative: string): Promise<string[]> {
  const text = await readFile(path.join(repoRoot, relative), "utf8")
  return paragraphs(text).filter((p) => p.startsWith(HOOK_MARKER))
}

/** Role ids a hook names, with `<placeholder>` expanded over the asset folder the hook names. */
async function roleIds(relative: string, hook: string): Promise<string[]> {
  const skillDir = relative.split("/").slice(0, 2).join("/")
  const ids = [...hook.matchAll(/`([a-z0-9-]+\/(?:[a-z0-9-]+|<[a-z-]+>))`/g)].map((m) => m[1])
  const expanded: string[] = []
  for (const id of ids) {
    if (!id.includes("<")) {
      expanded.push(id)
      continue
    }
    const folder = hook.match(/`(references\/[a-z0-9/-]+\/)`/)?.[1]
    if (!folder) throw new Error(`${relative}: ${id} has a placeholder but the hook names no asset folder`)
    const assets = await readdir(path.join(repoRoot, skillDir, folder))
    for (const asset of assets.filter((name) => name.endsWith(".md"))) {
      expanded.push(id.replace(/<[a-z-]+>/, asset.slice(0, -".md".length)))
    }
  }
  return expanded
}

async function roleList(): Promise<string[]> {
  const text = await readFile(path.join(repoRoot, "fork/roles.txt"), "utf8")
  return text
    .split("\n")
    .map((line) => line.split("#")[0].trim())
    .filter(Boolean)
}

describe("fork routing hooks", () => {
  test("hooks live only in the listed files, exactly once each", async () => {
    const withHook: string[] = []
    for (const file of await markdownFiles(path.join(repoRoot, "skills"))) {
      const relative = path.relative(repoRoot, file)
      const count = (await hookParagraphs(relative)).length
      if (count > 0) withHook.push(relative)
      if (HOOK_FILES.includes(relative)) expect({ relative, count }).toEqual({ relative, count: 1 })
    }
    expect(withHook.sort()).toEqual(HOOK_FILES)
  })

  test("each hook runs the lookup and falls back to the default", async () => {
    for (const relative of HOOK_FILES) {
      const [hook] = await hookParagraphs(relative)
      expect(hook).toContain(LOOKUP_COMMAND)
      expect(hook).toContain("model configured for this subagent's role")
      expect(hook).toContain("routing table")
      expect(hook).toContain("not the one whose instruction file you loaded")
    }
  })

  test("a hook after the precedence sentence is the very next paragraph", async () => {
    for (const relative of AFTER_PRECEDENCE) {
      const all = paragraphs(await readFile(path.join(repoRoot, relative), "utf8"))
      const at = all.findIndex((p) => p.includes(PRECEDENCE_SENTENCE))
      expect({ relative, found: at >= 0 }).toEqual({ relative, found: true })
      expect({ relative, next: all[at + 1]?.startsWith(HOOK_MARKER) }).toEqual({ relative, next: true })
    }
  })

  test("a SKILL.md without room sends the agent to its hook before dispatching", async () => {
    for (const [relative, hookFile] of Object.entries(POINTED)) {
      const text = await readFile(path.join(repoRoot, relative), "utf8")
      const target = hookFile.split("/").slice(2).join("/")
      expect({ relative, points: text.includes(`Read \`${target}\` before dispatching`) }).toEqual({ relative, points: true })
      expect({ relative, tiered: text.includes(PRECEDENCE_SENTENCE) }).toEqual({ relative, tiered: true })
    }
  })

  test("a hook without the precedence sentence lets a user-named model win", async () => {
    for (const relative of STANDALONE) {
      const [hook] = await hookParagraphs(relative)
      expect(hook).toContain("unless the user named a model for it in this conversation")
    }
  })

  test("hook role ids match fork/roles.txt and belong to their own skill", async () => {
    const fromHooks: string[] = []
    for (const relative of HOOK_FILES) {
      const [hook] = await hookParagraphs(relative)
      const skill = relative.split("/")[1]
      const ids = await roleIds(relative, hook)
      expect({ relative, any: ids.length > 0 }).toEqual({ relative, any: true })
      for (const id of ids) expect({ relative, id, skill: id.split("/")[0] }).toEqual({ relative, id, skill })
      fromHooks.push(...ids)
    }
    const listed = await roleList()
    expect(new Set(listed).size).toBe(listed.length)
    expect([...new Set(fromHooks)].sort()).toEqual([...listed].sort())
  })
})
