// Sets the package version in the two places that record it:
//  - pubspec.yaml's `version:` line
//  - lib/suqo_checkout.dart's exported suqoCheckoutVersion (test/version_test.dart fails if they
//    ever disagree)
// The release workflow runs it to apply the bump in the release PR. The Dart port of suqo-react's
// `npm version` + sync-version.mjs pair: pubspec.yaml has no tool that rewrites it in place.
//
//   node scripts/set-version.mjs <version>
import { readFileSync, writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

const version = process.argv[2]
if (!/^\d+\.\d+\.\d+$/.test(version ?? '')) {
  console.error('Usage: node scripts/set-version.mjs <major.minor.patch>')
  process.exit(1)
}

const root = new URL('../', import.meta.url)

const replaceLine = (relativePath, pattern, replacement) => {
  const path = fileURLToPath(new URL(relativePath, root))
  const source = readFileSync(path, 'utf8')
  if (!pattern.test(source)) {
    console.error(`set-version: no line matching ${pattern} in ${relativePath}`)
    process.exit(1)
  }
  writeFileSync(path, source.replace(pattern, replacement))
  console.log(`set-version: ${relativePath} = ${version}`)
}

// The lookaheads leave a CRLF checkout's \r in place, rather than failing to match or eating it.
replaceLine('pubspec.yaml', /^version: [^\r\n]*?(?=\r?$)/m, `version: ${version}`)
replaceLine(
  'lib/suqo_checkout.dart',
  /^const String suqoCheckoutVersion = '[^']*';(?=\r?$)/m,
  `const String suqoCheckoutVersion = '${version}';`
)
