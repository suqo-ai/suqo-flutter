// Computes the next version and notes with semantic-release's dry-run mode, which never tags or
// pushes. A normal `npx semantic-release` run tags the current commit as part of its core flow,
// whatever plugins are configured, which would put a tag on main before the release PR is
// reviewed. Ported from suqo-react, which ported it from the suqo repo.
import semanticRelease from 'semantic-release'
import { appendFileSync, writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

// The repo root, as clean-changelogs.mjs resolves it, so the two agree wherever this is run from.
const NOTES_PATH = fileURLToPath(new URL('../.next-notes.md', import.meta.url))

const output = (line) => {
  if (process.env.GITHUB_OUTPUT) appendFileSync(process.env.GITHUB_OUTPUT, `${line}\n`)
}

const result = await semanticRelease({ dryRun: true })

if (!result) {
  console.log('No release warranted.')
  output('released=false')
  process.exit(0)
}

const { version, notes } = result.nextRelease
console.log(`Next release: ${version}`)
writeFileSync(NOTES_PATH, notes)
output('released=true')
output(`version=${version}`)
