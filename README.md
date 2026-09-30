# Pull Schema — `pullschema/pull`

**Your pipeline pulls the schema.** The data model is designed in
[Pull Schema](https://pullschema.com); this action brings it into your
repository and opens a pull request whenever it changed — with the
**migration already written**.

```yaml
- uses: pullschema/pull@v1
  with:
    token: ${{ secrets.PULLSCHEMA_TOKEN }}
    model: 123
```

## What lands in the repository

| File | What for |
|---|---|
| `db/schema/<TABLE>.sql` | the current state, one file per table — the reviewer sees the table that changed |
| `db/migrations/V002__sales.sql` | the `ALTER` since last time, named for [Flyway](https://flywaydb.org) |
| `db/modelo.pullschema.json` | the whole model in a stable format — the memory for the next run |
| `db/.pullschema.json` | which model, which dialect, the number of the last migration |

The first run writes `V001__baseline.sql` (creates everything). Every later
change becomes the next version: `V002`, `V003`…

**The repository is the memory.** The action sends back the model file already
in your repository, and the migration is the difference between it and the
model as it is now. Nothing changed → nothing happens: no commit, no pull
request. Files in `schema/` carry no timestamp, so re-running never "changes" a
table.

## Folder layout

By default the repository gets `schema/<TABLE>.sql` for tables, and views and
routines live only in the migrations. Teams that already version databases
usually split by object type — pick the layout you use:

| `layout` | Tables | Views | Procedures | File name |
|---|---|---|---|---|
| `classico` (default) | `schema/` | — | — | `CUSTOMER.sql` |
| `simples` | `schema/tables/` | `schema/views/` | `schema/procedures/` | `CUSTOMER.sql` |
| `ssdt` (Visual Studio database project) | `dbo/Tables/` | `dbo/Views/` | `dbo/Stored Procedures/` | `CUSTOMER.sql` |
| `redgate` | `Tables/` | `Views/` | `Stored Procedures/` | `dbo.CUSTOMER.sql` |

Functions, triggers and sequences follow the same pattern. Set it once with the
`layout` input; from then on it lives in the repository's `.pullschema.json`,
where you can also write your own map:

```json
{
  "pastas": {
    "tabela": "database/{owner}/tables",
    "view": "database/{owner}/views",
    "procedure": "database/{owner}/procs"
  },
  "arquivo": "{owner}.{nome}",
  "repetiveis": true
}
```

A type the map does not mention gets no file. `{owner}` is the object's schema
(`dbo` on SQL Server when none is set). Changing the layout moves the files in
the next pull request — no migration is generated for that.

**`"repetiveis": true`** writes views and routines as Flyway *repeatable*
migrations (`migrations/repetiveis/R__1_dbo_V_SALES.sql`), each one dropping
and recreating its object so it can run again. The numbered migrations then
carry only tables and the objects that were removed — Flyway does not drop an
object whose `R__` file disappeared.

## Complete workflow

```yaml
name: Pull Schema
on:
  schedule: [{ cron: '0 9 * * 1-5' }]   # weekdays
  workflow_dispatch:                     # plus a "Run" button
permissions:
  contents: write
  pull-requests: write
jobs:
  pull:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: pullschema/pull@v1
        with:
          token: ${{ secrets.PULLSCHEMA_TOKEN }}
          model: 123
```

Setup, once:

1. In Pull Schema, create a **machine token** (account menu → *Tokens*) and
   save it as the repository secret `PULLSCHEMA_TOKEN`.
2. In *Settings → Actions → General*, tick **Allow GitHub Actions to create and
   approve pull requests**.

## Inputs

| Input | Default | |
|---|---|---|
| `token` | — | machine token (**required**; read-only by design) |
| `model` | — | model id, the number in its address (**required**) |
| `url` | `https://pullschema.com` | change only for a self-hosted installation |
| `path` | `db` | folder that receives the files |
| `dialect` | the model's | `mysql`, `postgres`, `oracle`, `sqlserver`, `bigquery`, `snowflake` — first run only |
| `mode` | `offline` | `online` = statements for a database that stays up (slower, avoid locks) |
| `layout` | `classico` | `simples`, `ssdt`, `redgate` — first run only, see [Folder layout](#folder-layout) |
| `force` | `false` | generate even when the model has errors no database accepts |
| `pull-request` | `true` | `false` only writes the files, for your own next step |
| `branch` | `pullschema/schema` | branch of the pull request |

## Outputs

`changed` (`true`/`false`), `migration` (e.g. `V003__sales.sql`, empty when the
change needs no DDL), `manual-steps` (changes the database cannot make by
command — explained inside the migration), `pull-request-url`.

```yaml
      - uses: pullschema/pull@v1
        id: schema
        with: { token: '${{ secrets.PULLSCHEMA_TOKEN }}', model: 123 }
      - if: steps.schema.outputs.manual-steps != '0'
        run: echo "Review the manual steps in ${{ steps.schema.outputs.migration }}"
```

## Two rules

- **Do not edit a migration after it ran.** Flyway checks the checksum of every
  applied file. If one came out wrong, fix the model — the next run writes the
  correction.
- **Do not delete `.pullschema.json`.** Without it the numbering cannot
  continue, and the server refuses rather than restart at `V001` on top of what
  already ran in production. To switch dialect, delete it *and*
  `modelo.pullschema.json` on purpose: the next migration is a new baseline.

## Other CI systems

`pull.sh` is the whole step and depends only on `bash`, `curl` and `unzip`.
Set `PS_TOKEN`, `PS_MODEL` (and optionally `PS_URL`, `PS_PATH`, `PS_DIALECT`,
`PS_MODE`, `PS_FORCE`, `PS_LAYOUT`) and run it — GitLab, Azure DevOps, Jenkins. The
[help page](https://pullschema.com/en/ajuda/git) has a ready GitLab CI job.

## Security

The token only reads: the package is built in memory and nothing in the model
changes. It is sent only in the `Authorization` header, over `https` (plain
`http` is refused except for `localhost`). Each run is recorded in the
account's audit trail as a model export.

## License

[MIT](LICENSE)
