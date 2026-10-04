# pesque

[English](README.md) | [Português (BR)](README.pt-BR.md)

![CI](https://github.com/zeetech/pesque/actions/workflows/ci.yml/badge.svg)
![License: WTFPL](https://img.shields.io/badge/license-WTFPL-blue.svg)
![Elixir](https://img.shields.io/badge/elixir-1.20%20%7C%20OTP%2029-purple.svg)

Um Personal Data Server do ATProto, self-hosted, escrito em Elixir.

Roda em um arquivo SQLite e um diretório de blobs. Sem Postgres, sem S3, sem
cluster. As partes do protocolo (CIDs, a Merkle Search Tree, DAG-CBOR, arquivos
CAR, JWTs, assinatura secp256k1) são construídas aqui em vez de trazidas prontas,
então o servidor todo é pequeno o bastante para ler e específico o bastante para
usar.

O nome parece PDS e significa "vai pescar" em português, o que pareceu adequado
para um servidor que alimenta o firehose.

## Executando

Requer Elixir 1.18+ e um compilador C para o driver do SQLite.

```bash
mix deps.get
mix phx.server
```

```bash
curl http://localhost:4000/xrpc/_health
```

As migrações rodam ao iniciar. O `_health` consulta o banco, então um servidor
cujo migrações não rodaram responde `503` em vez de um "ok" confiante. Aponte seu
monitor para ele.

## Colocando no ar

```bash
docker build -t pesque .
docker run -d --name pesque -p 4000:4000 \
  -v pesque-data:/data \
  -e PDS_HOSTNAME=pds.example.com \
  pesque
```

Ajuste `PDS_HOSTNAME` para o endereço real, senão as URLs anunciadas e o
`did:web` vão dizer `localhost`.

Coloque Caddy ou nginx na frente para o TLS. O container fala HTTP puro e
anuncia `https`, que é o que deveria acontecer atrás de um proxy.

## Criando uma conta

O registro começa fechado. A partir da máquina:

```bash
mix pesque.create_account --handle alice.example.com --email alice@example.com --password secret123
```

```
created alice.example.com (did:web:example.com)
```

O comando sobe a aplicação inteira, então pare o servidor antes ou use outro
`PDS_PORT`. Com `PDS_REGISTRATION=open`, `createAccount` vira um endpoint
aberto, o que só faz sentido onde você quer desconhecidos com conta.

## Antes de colocar dados reais

**Tudo que você escreve é público.** `getRecord`, `listRecords`, `getRepo`,
`getLatestCommit`, `describeRepo`, `subscribeRepos` e `getBlob` respondem sem
token, por decisão do protocolo. Não existe configuração de visibilidade por
repositório, e criar uma quebraria o protocolo. Trate cada registro como
publicado.

**E as fotos também.** O CID de um blob fica dentro do registro que o referencia,
então toda imagem de uma publicação pode ser buscada por qualquer pessoa que lê a
publicação, para sempre, sem limite de requisições. EXIF também não é removido,
então localização e identificadores do aparelho vão junto no JPEG. Remova no
cliente, antes de enviar.

**`:path_multi` não federa com a rede pública do Bluesky.** Ele usa
`did:web:example.com:user:alice`. A W3C permite, o ATProto não, então resolvedores
do ATProto ignoram. Esse é o preço de não depender do diretório PLC, que é
mantido pelo Bluesky. Use `:conformant_single` para estar na rede pública.

**Se o AppView público renderiza uma identidade `did:web` não foi testado.** Precisa
de um endereço HTTPS real e de uma conta ativa. Não presuma nada nos dois
sentidos.

**As escritas ficam mais devidas conforme o repositório cresce.** Cada escrita
reconstrói a MST inteira em vez de atualizá-la, e o `getRepo` monta o CAR
inteiro na memória (cerca de 1MB a cada 500 registros). Blocos nunca são
removidos. Tudo bem para milhares de registros, não para dezenas de milhares. É a
primeira coisa que eu mudaria.

## O que não existe

- **Validação de Lexicon.** Os registros são gravados como vieram.
  `Pesque.Lexicon` converte `$link` e `$bytes` entre JSON e CBOR, e só.
- **OAuth.** As sessões são tokens HS256 legados. Sem PAR, sem DPoP, sem escopos.
- **`did:plc` e sincronização entre servidores.** Duas instâncias do Pesque não
  conversam entre si.
- **AppView.** Isto serve um PDS, não um feed.

## Endpoints

Repositório: `createRecord`, `putRecord`, `deleteRecord`, `getRecord`, `listRecords`
Sincronização: `getRepo`, `getLatestCommit`, `subscribeRepos`
Blobs: `uploadBlob`, `getBlob`
Servidor: `createAccount`, `createSession`, `refreshSession`, `getSession`, `deleteSession`
Identidade: `resolveHandle`, `describeRepo`, documentos `did:web`

## Modos

| Modo | DID | Contas |
| --- | --- | --- |
| `:conformant_single` (padrão) | `did:web:example.com` | uma |
| `:path_multi` | `did:web:example.com:user:alice` | várias |

`:conformant_single` é a forma conforme o padrão e é o que um servidor público deve
usar. `:path_multi` dá a cada conta seu próprio DID e chave, ao custo da ressalva
de federação acima.

## Configuração

| Variável | Padrão | Função |
| --- | --- | --- |
| `PDS_DATA_DIR` | `data` | Diretório com todo o estado do servidor. |
| `PDS_HOSTNAME` | `localhost` | Endereço público. Define o `did:web`. |
| `PDS_PORT` | `4000` | Porta HTTP. |
| `PDS_MODE` | `conformant_single` | Ou `path_multi`. |
| `PDS_HANDLE` | `PDS_HOSTNAME` | Handle publicado no modo conformante. |
| `PDS_HANDLE_DOMAIN` | `PDS_HANDLE` | Contas recebem `alice.<domínio>`. |
| `PDS_REGISTRATION` | `closed` | `open` libera `createAccount` para qualquer um. |

Um `PDS_MODE` ou `PDS_REGISTRATION` desconhecido interrompe a inicialização em vez
de assumir um padrão, porque uma escolha silenciosa aparece depois como uma falha
difícil de entender.

## Backup

`data/` é tudo. Pare o servidor e copie o diretório.

A API de backup do SQLite dá um banco consistente, mas não o `blobs/`. Um
`cp -r` de um servidor em uso pode deixar uma linha de blob cujo arquivo nunca
chegou, ou um arquivo cuja linha nunca foi confirmada. Nada disso é fatal, mas os
dois lados discordam até um reinício.

**`data/server.secret` importa mais que qualquer outra coisa ali.** Um único
segredo HMAC assina tokens de todas as contas; quem o tiver age como qualquer
usuário do seu servidor, sem deixar rastro no repositório. As chaves por conta em
`keys/` são bem menos sensíveis: elas só permitem forjar commits de uma conta, e
um commit forjado falha na verificação de assinatura na hora.

## Licença

[WTFPL](LICENSE). Faça o que quiser com este código.