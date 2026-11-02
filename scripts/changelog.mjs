// CHANGELOG.md parsing shared by clean-changelogs.mjs (writing a release's notes in) and
// release-notes.mjs (reading them back out for the GitHub Release, or comparing releases).

// A release heading starts with its version: '## [0.0.2](…) (date)', '# [1.0.0](…)', '## 0.0.2'.
// semantic-release uses '#' or '##' depending on the preset and bump. Anchoring the version right
// after the hashes keeps '### Bug Fixes', the '# Changelog' title, and a hand-written heading that
// merely mentions a version ('## Migrating from 0.0.1') from being read as a release section.
export const SECTION_HEADING = /^#{1,2} \[?\d+\.\d+\.\d+/

// A release heading for exactly `version`.
export const headingFor = (version) =>
  new RegExp(`^#{1,2} \\[?${version.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\]?(?=[\\s(]|$)`)

export const splitSections = (content) => {
  const preamble = []
  const sections = []
  let current = null

  for (const line of content.replace(/\r\n/g, '\n').split('\n')) {
    if (SECTION_HEADING.test(line)) {
      if (current) sections.push(current)
      current = [line]
    } else if (current) {
      current.push(line)
    } else {
      preamble.push(line)
    }
  }
  if (current) sections.push(current)

  return { preamble, sections }
}

export const joinChangelog = (preamble, sections) => {
  const body = sections.map((section) => section.join('\n').trimEnd()).join('\n\n')
  return `${preamble.join('\n').trimEnd()}\n\n${body}\n`
}

// A section reduced to what defines the release: semantic-release stamps the run's date into the
// heading ('## [0.0.2](…) (2026-10-07)'), so two runs on different days produce different text for
// the same release. Drop the date and trailing whitespace so they compare equal.
export const normalizeSection = (lines) =>
  lines
    .map((line, i) => (i === 0 ? line.replace(/\s*\(\d{4}-\d{2}-\d{2}\)\s*$/, '') : line))
    .map((line) => line.trimEnd())
    .join('\n')
    .trim()
