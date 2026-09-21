# API contract and generation

`openapi.yaml` defines cotto's loopback HTTP contract between the native Qt client
and TypeScript server. Runtime validation and generated TypeScript types use the
same schema. Native C++ transport parsing is tested against fixture responses;
there is no Swift client or generator in this fork.

```zsh
bun run generate:api
bun run generate:api --check
```

Generation uses `openapi-typescript` and Prettier from the existing Bun lockfile.
The generated file is `Server/src/generated/api.ts`; do not edit it by hand.
`--check` compares regenerated output without modifying the file. Unknown flags
are rejected. Changing the schema requires regeneration and the server/native
protocol gates.

API version 1 remains stable. Optional fields are omitted rather than encoded as
null; dates use whole-second ISO-8601 UTC timestamps. `personalDictionary` is an
optional admission-time override, not a mutation of shared preferences. Pi's
Unix-socket protocol v2 and the recording-status file v1 are separate protocols.

See the [HTTP guide](../../docs/client-server-contract.md) for routes and
[architecture](../../docs/architecture.md) for ownership and data flow.
