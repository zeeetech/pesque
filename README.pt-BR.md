# pesque

[English](README.md) | [Português (BR)](README.pt-BR.md)

![CI](https://github.com/zeetech/pesque/actions/workflows/ci.yml/badge.svg)
![License: WTFPL](https://img.shields.io/badge/license-WTFPL-blue.svg)
![Elixir](https://img.shields.io/badge/elixir-1.20%20%7C%20OTP%2029-purple.svg)

Um Personal Data Server de ATProto, escrito em Elixir.

Ele faz criação de conta, OAuth (PAR, PKCE, DPoP), sessões legadas, repositórios
assinados, leituras públicas, storage de blobs, firehose e identidade que é
`did:web` por padrão e `did:plc` quando configurado. PDS guarda registros, assina
commits, entrega esses commits pra quem pedir, e responde `describeServer`
direito o suficiente pro cliente decidir se conversa com ele. Sem feed, sem
ranqueamento, sem fila de moderação.

O estado é um arquivo SQLite e um diretório de blobs. Sem Postgres, sem S3, sem
cluster. As primitivas de protocolo (CIDs, DAG-CBOR, Merkle Search Tree,
arquivos CAR, TIDs, JWTs, secp256k1) estão implementadas aqui em vez de puxadas
de dependência, porque uma implementação de referência que esconde o código de
protocolo atrás de uma dependência não tá te mostrando nadinha.

O nome parece PDS e significa "vai pescar" em português.

## Rodando

Precisa de Elixir 1.18+ e um toolchain de C (o driver do SQLite compila da
fonte).

```bash
mix deps.get
mix phx.server
```

```bash
curl http://localhost:4000/xrpc/_health
```

Pra hospedar uma conta:

```bash
mix pesque.create_account --handle alice.example.com --email alice@example.com
```

As migrações rodam no boot e o `_health` consulta a tabela de usuários, então um
servidor cujas migrações nunca rodaram responde `503` em vez de um ok alegre.
Docker, release e TLS estão no [guia de instalação](docs/guides/installation.md).

Ainda não tem: `signPlcOperation` e `requestPlcOperationSignature` (o PDS antigo
assina a mudança) e consentimento granular no OAuth.

## Guias

- [Instalação](docs/guides/installation.md) - local, Docker, release, TLS, primeira conta
- [Identidade](docs/guides/identity.md) - DIDs, handles, os dois modos, quando a federação quebra
- [Operação](docs/guides/operations.md) - backup, upgrade, limites, o que seus dados expõem
- [Migração](docs/guides/migration.md) - mover uma conta existente pra este servidor
- [Arquitetura](docs/reference/architecture.md) - mapa dos módulos, caminho da escrita, layout de storage

Os guias são só em inglês. Este README tem espelho em
[English](README.md).

## Convenções antes de ler o código

- Tudo que tem cara de protocolo é puro: `Pesque.CBOR`, `Pesque.CID`,
  `Pesque.Mst`, `Pesque.Car`, `Pesque.Commit` e `Pesque.Lexicon.Validate`
  recebem os argumentos, não tocam em processo nenhum, e levantam ou respondem
  em vez de logar.
- Tudo que encosta no mundo real mora em `Pesque.RepoStore` (SQL),
  `Pesque.Storage` e `Pesque.Keys` (arquivos), `Pesque.Accounts` (domínio) e
  `PesqueWeb.*` (HTTP).
- Um processo por repositório, guardando o mapa de entradas e a chave de
  assinatura. As escritas são serializadas por ele.
- Razões de domínio são tuplas com tag. `PesqueWeb.Xrpc.Errors` é o único lugar
  onde uma vira status e mensagem.

O código é a fonte da verdade. Onde estes docs discordam dele, o código manda.

## Licença

[WTFPL](LICENSE). Faz o que quiser com ela.
