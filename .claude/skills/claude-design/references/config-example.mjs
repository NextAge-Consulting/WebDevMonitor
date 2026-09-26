/* A project's Claude Design system config — copy to your UI package (e.g.
 * packages/ui/design-system/design-system.config.mjs) and fill in.
 *
 * Paths: `package` is from the repository root; `feed`, `tokens`, `typeRoles`,
 * `styles`, `css.file`, `types.dir`, `out` and `docSources.sourceRoot` are from
 * the package; `cover` and `assets` are from the config's own folder;
 * `readme.source` and `docSources.inventory` / `design` are from the repository
 * root.
 *
 * Each component's guidelines come from ONE source, never restated here:
 *   { inventory: "Name" } → the `| \`Name\` | … |` row of the UI inventory
 *   { design: "Heading" } → that `###` section of the design doc
 *   { source: "path" }    → the doc comment above the component in <sourceRoot>/<path>,
 *                            else that file's leading doc comment
 * `render` is the body of a preview script, given `U` (window.<namespace>), `h`
 * (React.createElement) and `icon(name)`, returning one element. A preview whose
 * point is an open overlay sets `cardMode: 'overlay'` so the render check
 * verifies the overlay opens and sits beside its trigger. */

const components = [
  {
    name: 'Button',
    group: 'Actions',
    height: 96,
    doc: { design: 'Buttons' },
    render: `h('div', { className: 'flex gap-2' }, h(U.Button, null, 'Save'), h(U.Button, { variant: 'outline' }, 'Cancel'))`,
  },
  {
    name: 'Popover',
    group: 'Overlays',
    height: 220,
    cardMode: 'overlay',
    doc: { inventory: 'Popover' },
    render: `h(U.Popover, { defaultOpen: true },
      h(U.PopoverTrigger, { asChild: true }, h(U.Button, { variant: 'outline' }, 'Filters')),
      h(U.PopoverContent, null, 'Status, owner and date.'))`,
  },
]

export default {
  title: 'Acme',
  namespace: 'Acme', // the bundle's global: window.Acme
  artifact: '', // the Design System's claude.ai address; /ui-design publish-system fills it on first publish
  tagline: 'One sentence in the system’s own voice.',
  timeZone: 'America/New_York', // the project's IANA zone; the build dates each sync in it
  package: 'packages/ui',
  feed: 'src/index.ts', // the barrel of every presentational component
  tokens: ['src/tokens.css'], // :root / dark blocks of custom properties
  typeRoles: { file: 'src/type.css', utilityPrefix: 'type-' }, // `@utility type-*` blocks
  typeFamilies: { sans: 'font-sans', mono: 'font-mono' }, // family → the token holding its stack
  styles: 'src/styles.css', // spacing aliases and @fontsource-variable imports
  // themeSelectors: { light: [':root'], dark: ['.dark'] }, // only when not the common forms
  families: { radius: '^radius-', shadow: '^shadow-', skip: '^(step-|weight-|font-|size-)' },
  spacing: { base: 4, steps: [0, 1, 2, 3, 4, 6, 8, 12, 16] },
  css: { build: 'npm run build:css', file: 'dist/feed.css', darkClass: '.dark', lightClass: '.light' }, // the classes that force a theme
  types: { build: 'npm run build:js', dir: 'dist' },
  icons: 'lucide-react', // a package exporting `icons`; omit for none
  previewStyle: 'body{margin:0;padding:16px;background:var(--background);color:var(--foreground)}',
  readme: {
    source: 'design.md',
    sections: ['Overview', 'Colors', 'Typography'],
    vocabularyIntro: 'Output that uses these classes drops into the app with no restyling.',
    vocabulary: [
      ['A colour token', '`bg-<token>`, `text-<token>`, `border-<token>`'],
      ['A component', '`window.Acme.<Name>` — the real component the app ships'],
    ],
  },
  docSources: { inventory: '.claude/rules/project/ui-inventory.md', design: 'design.md', sourceRoot: 'src' },
  components,
  notPreviewed: { AppShell: 'the whole application frame; a design composes its own screen inside it' },
  cover: 'cover.html', // optional: the system's cover, a preview document
  assets: 'assets', // optional: asset-group READMEs (images are uploaded at publish)
  out: 'dist/design-system',
}
