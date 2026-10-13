# pesque

[English](README.md) | [Português (BR)](README.pt-BR.md)

![CI](https://github.com/zeeetech/pesque/actions/workflows/ci.yml/badge.svg)
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

## Faz o deploy

Instala a CLI, escreve um conf, sobe o servidor:

```bash
curl -fsSL https://github.com/zeeetech/pesque/releases/latest/download/install.sh | sh
pesque config template --out pesque.conf
```

Edita o `pesque.conf` com o domínio que os clientes vão usar, e então:

```bash
pesque up
pesque account create --handle alice.example.com --email alice@example.com
```

O instalador verifica e instala a CLI `pesque`, só isso. Não tem wizard de
setup nem TLS na caixa: o reverse proxy e os certificados são responsabilidade
de quem opera. Aponta o teu proxy pra porta publicada (`127.0.0.1:4000` por
padrão) e adiciona os registros de DNS por conta própria.

A CLI fala com um de dois backends, escolhido com `--backend docker|systemd`
ou `PESQUE_BACKEND`. O `docker` (padrão) cria e comanda um container: `up` roda
ele se não existir e inicia senão, `down` para mantendo os dados, `update [tag]`
puxa uma imagem nova e recria o container com as mesmas configurações. O
`systemd` roda a release como um serviço systemd nativo e a unit comanda o
ciclo de vida, então `up`, `down`, `restart` e `update` são no-op lá; NixOS é
detectado como systemd. Atualização é manual, não tem auto-update.

Depois da primeira conta:

```bash
pesque doctor          # preflight de federação
pesque migrate --old-pds https://bsky.social --handle alice.example.com --email alice@example.com
pesque update          # puxar uma imagem nova e recriar o container
pesque logs -f         # acompanhar os logs do servidor
```

`account create` e `migrate` perguntam a senha com echo desligado, ou leem do
stdin (`echo secret | pesque ...`), então ela nunca cai no histórico do shell
nem no ambiente. Docker cru, release, TLS e todas as opções de configuração
estão no [guia de instalação](docs/guides/installation.md).

## Rodando da fonte

Precisa de Elixir 1.19+ no OTP 28+ e um toolchain de C (o driver do SQLite
compila da fonte).

```bash
mix deps.get
mix phx.server
curl http://localhost:4000/xrpc/_health
```

Pra hospedar uma conta:

```bash
mix pesque.account create --handle alice.example.com --email alice@example.com
```

`mix pesque.create_account` é a mesma task com o nome antigo, mantida pra guias
e scripts mais velhos continuarem funcionando.

As migrações rodam no boot e o `_health` consulta a tabela de usuários, então um
servidor cujas migrações nunca rodaram responde `503` em vez de um ok alegre.

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

## Perguntas comuns

- **Como consigo um servidor?** O instalador e três comandos:
  [Faz o deploy](#faz-o-deploy). Um container Docker ou um serviço systemd; o
  proxy de TLS é teu.
- **Como adiciono outra conta?**
  `pesque account create --handle alice.example.com --email alice@example.com`;
  pede a senha com echo desligado.
- **Como faço backup e restauro?** `pesque backup [--out DIR]` roda com o
  servidor no ar; `pesque restore ARQUIVO.tar.gz` pede o servidor parado.
  [Operação](docs/guides/operations.md) tem o cronograma e os riscos.
- **Como atualizo?** `pesque update` puxa uma imagem nova e recria o container
  (backend docker, só manual); no systemd tu atualiza a release por conta
  própria.
- **Como movo uma conta pra cá?** `pesque migrate --old-pds https://bsky.social
  --handle alice.example.com --email alice@example.com`; a mudança é uma via.
  [Migração](docs/guides/migration.md) tem a dança completa.
- **Como movo uma conta pra fora?** Ainda não dá: este PDS não assina a
  mudança (`signPlcOperation`).
- **Como aceito registros de coleção de outro app?** Já aceita. Uma coleção pra
  qual este servidor não embarca lexicon é guardada como veio e reportada
  `validationStatus: "unknown"`, a mesma resposta do PDS de referência; a
  escrita só é recusada quando quebra um lexicon que o servidor embarca
  (`priv/lexicons`). `pesque lexicon add --from https://github.com/org/lexicons`
  instala mais documentos em `data/lexicons` pra resolução (permission sets do
  OAuth), não pra enforcement; arquivos `com.atproto` são pulados pra um
  terceiro não sobrepor o set vendido.
- **Onde fica o código?** Aqui. As primitivas de protocolo moram em
  `lib/pesque` de propósito; [Arquitetura](docs/reference/architecture.md) é o
  mapa.

## Contribuindo

Leia o [CONTRIBUTING.md](CONTRIBUTING.md) antes do código: setup de dev, a
régua do `mix precommit` e as convenções que a árvore espera.

## Licença

[WTFPL](LICENSE). Faz o que quiser com ela.
