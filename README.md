# pesque

A minimal, self-hosted ATProto Personal Data Server written in Elixir. The name sounds like PDS and means "go fish" in Portuguese, which felt right for a server that feeds the firehose.

One user, one binary, one SQLite file. The reference PDS (TypeScript, PostgreSQL, S3, Node) is built for scale-out hosting. Pesque targets the opposite end: a single account, idle memory in the tens of megabytes, and a data directory you can back up with `cp`.

Serialization, CIDs, the Merkle Search Tree, CAR archives, and JWTs are hand-built, because that is where the protocol actually lives. Dependencies stay minimal: Phoenix (API-only), Bandit, Ecto with SQLite.

## Running with Docker

Build the image:

```bash
docker build -t pesque .
```

Run it, with a volume for the data directory (the entire server state lives there):

```bash
docker run -d \
  --name pesque \
  -p 4000:4000 \
  -v pesque-data:/data \
  -e PHX_HOST=pds.example.com \
  -e SECRET_KEY_BASE=$(mix phx.gen.secret) \
  -e DATABASE_PATH=/data/pesque.db \
  pesque
```

Migrations run automatically on boot. Check the health endpoint:

```bash
curl http://localhost:4000/xrpc/_health
```

For a real deployment, put the container behind TLS (Caddy or nginx terminating) and set `PHX_HOST` to the public hostname.

## Running locally

```bash
mix setup
mix phx.server
```

The server answers at `http://localhost:4000`.

## Configuration

| Variable          | Default        | Purpose                                    |
| ----------------- | -------------- | ------------------------------------------ |
| `PHX_HOST`        | `example.com`  | Public hostname. Drives the `did:web`.     |
| `PORT`            | `4000`         | HTTP port.                                 |
| `DATABASE_PATH`   | (required)     | Path of the SQLite file.                   |
| `SECRET_KEY_BASE` | (required)     | Phoenix secret. Generate with `mix phx.gen.secret`. |
| `POOL_SIZE`       | `5`            | Database connection pool size.             |

## The did:web caveat

Identity comes from `did:web`, not the PLC directory. That keeps the server self-contained: your DID document is just a JSON file served from your own domain. The tradeoff is that your identity is only as stable as your control of the domain and the signing key on disk. If the domain lapses or the key file is lost, the identity goes with it. For a single-user self-hosted node this tradeoff is usually right, but know what you are accepting.

## Backups

Back up the whole data directory. It is the entire server state: the SQLite database (WAL sidecars included), the signing key, and the server secret. Stop the container or use the SQLite backup API if you want a consistent snapshot.
