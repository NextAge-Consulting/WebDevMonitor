// node --test .claude/skills/claude-design/scripts/resolve.test.mjs
import assert from 'node:assert/strict'
import { describe, it } from 'node:test'
import { parseTokenBlocks, resolveColor } from './resolve.mjs'

const env = new Map([
  ['hue', '252.8'],
  ['input', 'oklch(0.4217 0.0320 var(--hue))'],
  ['accent', 'var(--input)'],
])
const colors = new Set(['input', 'accent'])

/** The oklab() channels of a resolved value, failing if it is not oklab. */
function oklabParts(value) {
  const m = /^oklab\(([-\d.]+) ([-\d.]+) ([-\d.]+)(?: \/ ([\d.]+))?\)$/.exec(value)
  if (!m) throw new Error(`expected an oklab() value, got ${value}`)
  return m.slice(1).filter((x) => x !== undefined).map(Number)
}

const close = (actual, expected) => assert.ok(Math.abs(actual - expected) < 0.001, `${actual} is not close to ${expected}`)

describe('resolveColor', () => {
  it('writes a numeric knob into the colour', () => {
    assert.equal(resolveColor('oklch(0.5 0.01 var(--hue))', env, colors), 'oklch(0.5 0.01 252.8)')
  })

  it('keeps a reference to another colour as an alias, so it follows that token per theme', () => {
    assert.equal(resolveColor('var(--input)', env, colors), '{input}')
  })

  it('writes transparent as a zero-alpha literal, since the format refuses named colours', () => {
    assert.equal(resolveColor('transparent', env, colors), 'oklch(0 0 0 / 0)')
  })

  // Chromium computes color-mix(in oklab, X 30%, transparent) as X at alpha 0.3.
  it('resolves a mix with transparent to the colour at that opacity, through an alias', () => {
    assert.equal(resolveColor('color-mix(in oklab, var(--accent) 30%, transparent)', env, colors), 'oklch(0.4217 0.0320 252.8 / 0.3)')
  })

  // Expected values are what Chromium computes for the same expressions.
  it('mixes two solid colours the way the browser does', () => {
    const [L, a, b] = oklabParts(resolveColor('color-mix(in oklab, oklch(0.52 0.17 252.8) 40%, oklch(0.9 0.02 95))', env, colors))
    close(L, 0.748)
    close(a, -0.021154)
    close(b, -0.0530046)
  })

  it('premultiplies alpha when one side is translucent', () => {
    const [L, a, b, alpha] = oklabParts(resolveColor('color-mix(in oklab, oklch(0.52 0.17 252.8 / 0.5) 50%, oklch(0.9 0 0))', env, colors))
    close(L, 0.773333)
    close(a, -0.0167568)
    close(b, -0.0541324)
    close(alpha, 0.75)
  })

  it('fails loudly on a construct it does not know, instead of dropping the token', () => {
    assert.throws(() => resolveColor('color-mix(in srgb, red 50%, blue)', env, colors), /unsupported/)
    assert.throws(() => resolveColor('light-dark(white, black)', env, colors), /unsupported/)
    assert.throws(() => resolveColor('red', env, colors), /unsupported/)
  })
})

describe('parseTokenBlocks', () => {
  it('takes a token usage from the comment above or beside it, and not from a group header', () => {
    const [block] = parseTokenBlocks(`:root {
  /* ─── surfaces ─── */
  /* the page canvas */
  --background: oklch(1 0 0);
  --card: oklch(0.9 0 0); /* a resting container */
  /* ─── lines ─── */
  --border: oklch(0.8 0 0);
}`)
    assert.equal(block.theme, 'light')
    assert.deepEqual(block.decls, [
      { name: 'background', value: 'oklch(1 0 0)', usage: 'the page canvas' },
      { name: 'card', value: 'oklch(0.9 0 0)', usage: 'a resting container' },
      { name: 'border', value: 'oklch(0.8 0 0)', usage: '' },
    ])
  })

  it('recognises the common dark-theme selectors', () => {
    for (const selector of ['.dark', 'html[data-theme="dark"]', '[data-theme=dark]', ':root.dark']) {
      const blocks = parseTokenBlocks(`:root {\n  --a: oklch(1 0 0);\n}\n${selector} {\n  --a: oklch(0 0 0);\n}`)
      assert.deepEqual(
        blocks.map((b) => b.theme),
        ['light', 'dark'],
        selector,
      )
    }
  })

  it('takes the theme selectors a project names instead', () => {
    const blocks = parseTokenBlocks(`:root {\n  --a: oklch(1 0 0);\n}\n.theme-night {\n  --a: oklch(0 0 0);\n}`, {
      light: [':root'],
      dark: ['.theme-night'],
    })
    assert.deepEqual(
      blocks.map((b) => b.theme),
      ['light', 'dark'],
    )
  })

  it('refuses a token block under a selector it does not know, rather than skipping it', () => {
    assert.throws(() => parseTokenBlocks(`:root {\n  --a: oklch(1 0 0);\n}\n.theme-ocean {\n  --a: oklch(0 0 0);\n}`), /unrecognised selector/)
  })

  it('reads dark values written once under a nested @variant dark', () => {
    const blocks = parseTokenBlocks(`:root {\n  --a: oklch(1 0 0);\n}\n:root {\n  @variant dark {\n    /* the page */\n    --a: oklch(0 0 0);\n  }\n}`)
    assert.deepEqual(blocks.map((b) => b.theme), ['dark', 'light'])
    assert.deepEqual(blocks[0].decls, [{ name: 'a', value: 'oklch(0 0 0)', usage: 'the page' }])
  })

  it('refuses a nested variant other than dark, rather than skipping it', () => {
    assert.throws(() => parseTokenBlocks(`:root {\n  @variant print {\n    --a: oklch(0 0 0);\n  }\n}`), /unrecognised variant/)
  })

  it('ignores blocks that declare no custom properties', () => {
    assert.equal(parseTokenBlocks(`:root {\n  --a: oklch(1 0 0);\n}\nbody {\n  margin: 0;\n}`).length, 1)
  })

  it('does not carry a comment across a blank line', () => {
    const [block] = parseTokenBlocks(`:root {
  /* about something else */

  --ring: oklch(0.6 0.1 250);
}`)
    assert.equal(block.decls[0].usage, '')
  })
})
