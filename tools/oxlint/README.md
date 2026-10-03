# Anti-slop lint rules

Run `bun run lint:anti-slop` to check the baseline rules, or `bun run lint` to run
all configured lint checks. The active severities and file exclusions live in
`.oxlintrc.json`.

The initial profile reports these rules as warnings while existing findings are
reviewed for migration:

- `no-chained-type-assertions`
- `no-known-value-widening`
- `no-widen-then-assert`

These rules inspect TypeScript/JavaScript, including script blocks in Svelte
components. They do not lint Svelte template expressions. Legitimate boundary
validation can continue to accept `unknown` and use runtime narrowing. Review
findings against the actual contracts before changing code or raising severity.

The existing linter configuration remains authoritative for other rules.
Oxlint's default rules are disabled so this command adds only the chosen profile.
Generated outputs, installed agent assets, and vendored rule code are excluded;
application code and tests remain included. The separate stricter and Effect
profiles are not enabled.

## Source and updates

`anti-slop/` is a vendored copy from the shared `install-anti-slop` skill,
originating from <https://github.com/dmmulroy/anti-slop>. The bundled snapshot was
copied on 2026-10-02; its exact upstream commit was not recorded in the installed
bundle. Its source-file inventory SHA-256 is `4d3dd6afb28099dbea6f9d9a0e065b0568198099ec2ecab0db4e2536463ccb9f`.
The upstream MIT license is preserved in `anti-slop/LICENSE`.

The copy's TypeScript sources are unmodified. Keep the original copy available
through version control when updating, review upstream changes, and preserve
local rule selections and justified exceptions. `oxlint` and `@oxlint/plugins`
are pinned development dependencies; the package manifest and lockfile record
the installed versions.
