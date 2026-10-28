# pesque

[English](README.md) | [Português (BR)](README.pt-BR.md)

![CI](https://github.com/zeeetech/pesque/actions/workflows/ci.yml/badge.svg)
![License: WTFPL](https://img.shields.io/badge/license-WTFPL-blue.svg)
![Elixir](https://img.shields.io/badge/elixir-1.20%20%7C%20OTP%2029-purple.svg)

Um Personal Data Server de ATProto, escrito em Elixir.

Ele faz criação de conta, OAuth (PAR, PKCE, DPoP), sessões legadas,
repositórios assinados, leituras públicas, storage de blobs, firehose e
identidade do servidor `did:web`, com identidades de conta escolhidas na
criação. PDS guarda registros, assina commits, entrega esses commits pra
quem pedir, e responde `describeServer` direito o suficiente pro cliente
decidir se conversa com ele. Sem feed, sem ranqueamento, sem fila de
moderação.

O estado é um arquivo SQLite e um diretório de blobs. Sem Postgres, sem S3,
sem cluster. As primitivas de protocolo (CIDs, DAG-CBOR, Merkle Search Tree,
arquivos CAR, TIDs, JWTs, secp256k1) estão implementadas aqui em vez de
puxadas de dependência, porque uma implementação de referência que esconde o
código de protocolo atrás de uma dependência não tá te mostrando nadinha.

O nome parece PDS e significa "vai pescar" em português.

## Faz o deploy

Dois caminhos suportados, ambos rodando a mesma imagem OCI pinada. Em
qualquer host Docker, pega o bundle Compose do
[release mais novo](https://github.com/zeeetech/pesque/releases/latest)
(verifica contra o `SHA256SUMS`) e:

```bash
tar -xzf pesque-compose-<version>.tar.gz && cd pesque
./pesque init                        # escreve o pesque.conf, cria o backups/
$EDITOR pesque.conf                  # o domínio que os clientes vão usar
docker compose up --detach --wait
./pesque account create --handle alice.example.com --email alice@example.com
```

No NixOS, o módulo do flake roda a mesma imagem sob o systemd:
[Instalação](docs/installation.md#nixos).

Não tem wizard de setup nem TLS na caixa: o reverse proxy e os certificados
são responsabilidade de quem opera. Aponta o proxy pra porta publicada
(`127.0.0.1:4000` por padrão) e adiciona os registros de DNS por conta
própria. O ciclo de vida é o Docker Compose (ou `systemctl`); o comando
`pesque`, um script de shell curto no Docker e um comando configurado no
NixOS, roda tudo que toca nos dados diretamente, e atualização é manual.

Depois da primeira conta:

```bash
./pesque doctor          # preflight de federação
./pesque migrate --old-pds https://bsky.social --handle alice.example.com --email alice@example.com
./pesque backup          # seguro com o servidor no ar; o restore é a frio
./pesque account list
```

`account create` e `migrate` perguntam a senha com echo desligado, ou leem
do stdin (`echo secret | ./pesque ...`), então ela nunca cai no histórico do
shell nem no ambiente.

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
mix run -e 'Pesque.Cli.main()' account create --handle alice.example.com --email alice@example.com
```

O verb sobe a aplicação inteira, endpoint inclusive, roda e sai. As
migrações rodam no boot e o `_health` consulta a tabela de usuários, então
um servidor cujas migrações nunca rodaram responde `503` em vez de um ok
alegre.

Ainda não tem: consentimento granular no OAuth.

## Guias

- [Instalação](docs/installation.md) - single ou multi, Docker, NixOS, o
  proxy TLS, configuração, verificação
- [Operação](docs/operations.md) - backup, contas, mover uma conta pra cá,
  upgrades, limites, o que seus dados expõem

Os guias são só em inglês. Este README tem espelho em
[Português (BR)](README.pt-BR.md).

## Perguntas comuns

- **Como consigo um servidor?** O bundle Compose e quatro comandos:
  [Faz o deploy](#faz-o-deploy). Um container; o proxy TLS é teu.
- **Como adiciono outra conta?**
  `./pesque account create --handle alice.example.com --email alice@example.com`;
  pede a senha com echo desligado. Contas seguintes precisam de código de
  convite, a menos que o registro esteja aberto.
- **Como faço backup e restauro?** `pesque backup` roda com o servidor no
  ar; `pesque restore NOME_DO_ARQUIVO` é a frio, para o servidor antes.
  [Operação](docs/operations.md#backup-and-restore) tem o cronograma e os
  riscos.
- **Como atualizo?** Manual. Docker: extrai um bundle mais novo por cima do
  mesmo diretório e `docker compose up --detach --wait`. NixOS: sobe o tag
  pinado da imagem e `nixos-rebuild switch`.
- **Como movo uma conta pra cá?**
  `./pesque migrate --old-pds https://bsky.social --handle alice.example.com
  --email alice@example.com`; a mudança é uma via só e o servidor novo
  precisa estar em `multi`.
  [Operação](docs/operations.md#moving-an-account-in) tem a dança completa.
- **Como movo uma conta pra fora?** O PDS de destino conduz a mudança; este
  servidor assina o passo de identidade (`signPlcOperation`), e o código de
  confirmação chega em você, operador, pelo log ou pelo
  `pesque account plc-token`, não numa caixa de entrada.
  [Operação](docs/operations.md#accounts).
- **Como aceito registros de coleção de outro app?** Já aceita. Uma coleção
  pra qual este servidor não embarca lexicon é guardada como veio e
  reportada `validationStatus: "unknown"`, a mesma resposta do PDS de
  referência. Não há nada pra instalar.
- **Onde fica o código?** Aqui. As primitivas de protocolo moram em
  `lib/pesque` de propósito; o [CONTRIBUTING.md](CONTRIBUTING.md) mapeia as
  camadas.

## Contribuindo

Leia o [CONTRIBUTING.md](CONTRIBUTING.md) antes do código: setup de dev, a
régua do `mix precommit` e as convenções que a árvore espera.

## Licença

[WTFPL](LICENSE). Faz o que quiser com ela.
