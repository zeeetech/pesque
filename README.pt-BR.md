# pesque

[English](README.md) | [Português (BR)](README.pt-BR.md)

![CI](https://github.com/zeetech/pesque/actions/workflows/ci.yml/badge.svg)
![License: WTFPL](https://img.shields.io/badge/license-WTFPL-blue.svg)
![Elixir](https://img.shields.io/badge/elixir-1.20%20%7C%20OTP%2029-purple.svg)

Um Personal Data Server do ATProto, self-hosted, escrito em Elixir. O nome parece PDS e significa "vai pescar" em português, o que pareceu adequado para um servidor que alimenta o firehose.

O servidor inteiro cabe em um arquivo SQLite. O PDS de referência (TypeScript, PostgreSQL, S3, Node) foi construído para escalar horizontalmente. O Pesque vai para o outro extremo: poucas contas, dezenas de megabytes de memória ociosa, e um diretório de dados que se copia com `cp`.

CIDs, a Merkle Search Tree, arquivos CAR e JWTs são construídos à mão, porque é neles que o protocolo realmente está. As dependências são poucas: Phoenix (somente API), Bandit, Ecto com SQLite.

## Antes de colocar dados no servidor

**Todo repositório local pode ser lido por qualquer pessoa.** `getRecord`, `listRecords`, `getRepo`, `getLatestCommit`, `describeRepo` e `subscribeRepos` respondem sem token, por decisão do protocolo. Não existe configuração de visibilidade por repositório, e criar uma quebraria o protocolo: o papel de um PDS é justamente esse. Considere tudo que você escreve como público.

**O modo `:path_multi` não se conecta à rede pública do Bluesky.** As contas recebem identificadores como `did:web:example.com:user:alice`. O padrão did:web da W3C permite identificadores com caminho, mas o ATProto restringe o did:web ao nível do domínio, então resolvedores do ATProto não seguem esse formato. É o preço de não depender do diretório PLC, que é mantido pelo Bluesky: o Pesque continua autossuficiente. Se quiser estar na rede pública, use o modo `:conformant_single`.

Uma ressalva menor: se o AppView público do Bluesky exibe uma identidade `did:web` **não foi testado**. Isso exige um endereço HTTPS público e uma conta real, e ficou para depois. Não presuma nada nos dois sentidos.

## O que ainda não existe

- **Blobs.** Sem `uploadBlob` e `getBlob`. Publicações com imagem ou vídeo não funcionam.
- **Validação de Lexicon.** `Pesque.Lexicon` converte `$link` e `$bytes` entre JSON e CBOR. Ele não confere um registro contra o seu Lexicon, então um registro malformado é gravado como veio.
- **OAuth.** As sessões são tokens HS256 legados, sem PAR, DPoP, escopos ou client IDs.
- **Sincronização entre servidores e `did:plc`.** Duas instâncias do Pesque não conversam entre si.
- **AppView.** O Pesque serve um repositório, não um feed.

Tudo o mais está implementado: armazenamento com MST, commits e exportação CAR, os endpoints de leitura e escrita, uma chave de assinatura por conta, documentos `did:web`, resolução de handles e o firehose.

## Executando

Requer Elixir 1.18 ou superior e um compilador C para o driver do SQLite.

```bash
mix deps.get
mix phx.server
```

As migrações rodam ao iniciar. O servidor responde em `http://localhost:4000`:

```bash
curl http://localhost:4000/xrpc/_health
```

Sem configuração, o Pesque sobe em `:conformant_single`, na porta 4000, e escreve em `./data`.

## Criando uma conta

O registro começa fechado, então `createAccount` por HTTP responde:

```json
{"error":"InvalidRequest","message":"registration is closed; accounts are provisioned by the operator"}
```

 Para provisionar, use a máquina local:

```bash
mix pesque.create_account --handle alice.example.com --email alice@example.com --password secret123
```

```plain
created alice.example.com (did:web:example.com)
```

Esse comando sobe a aplicação inteira, então a porta precisa estar livre: pare o servidor antes, ou provisione de outro terminal com um `PDS_PORT` diferente.

Com `PDS_REGISTRATION=open`, `createAccount` passa a aceitar qualquer chamada. Use apenas onde você quer desconhecidos com conta.

O handle tem o formato `<usuário>.<domínio>`, por exemplo `alice.example.com` com `PDS_HANDLE_DOMAIN=example.com`. O domínio é seu, então colisões com outros servidores dependem de você. Entre contas locais não há colisão: duas chamadas simultâneas com o mesmo handle produzem exatamente uma conta.

## Modos

| Modo | DID | Documento DID | Contas |
| --- | --- | --- | --- |
| `:conformant_single` (padrão) | `did:web:example.com` | `/.well-known/did.json` | uma |
| `:path_multi` | `did:web:example.com:user:alice` | `/user/alice/did.json` | várias |

`:conformant_single` é a forma que segue o padrão: um único DID para o servidor, no nível do domínio. Ele comporta exatamente uma conta, e essa conta é o próprio servidor. É o que um servidor público deve usar.

`:path_multi` dá a cada conta seu próprio DID e sua própria chave de assinatura, ao custo da limitação de federação mencionada acima. Serve para uma instância de comunidade, um grupo privado ou um homelab onde você controla a resolução.

O padrão did:web codifica portas não padrão em porcentagem, então a porta 3000 aparece como `did:web:example.com%3A3000`. Um DID em produção não carrega porta.

## Configuração

Tudo é lido do ambiente na inicialização. Um valor desconhecido em `PDS_MODE` ou `PDS_REGISTRATION` interrompe a execução em vez de assumir um padrão, porque uma escolha silenciosa aparece depois como uma falha difícil de entender.

| Variável | Padrão | Função |
| --- | --- | --- |
| `PDS_DATA_DIR` | `data` (`tmp/test` em testes) | Diretório com todo o estado do servidor. |
| `PDS_HOSTNAME` | `localhost` | Endereço público. Define o `did:web`. |
| `PDS_PORT` | `4000` | Porta HTTP. |
| `PDS_MODE` | `conformant_single` | `conformant_single` ou `path_multi`. |
| `PDS_HANDLE` | igual a `PDS_HOSTNAME` | Handle publicado no modo conformante. Ignorado em `:path_multi`. |
| `PDS_HANDLE_DOMAIN` | igual a `PDS_HANDLE` | Domínio das contas: `alice.<domínio>`. |
| `PDS_REGISTRATION` | `closed` | `open` libera `createAccount` para qualquer um. |

O pool de conexões do banco é fixo em 4. O endpoint anuncia `https` em `PDS_HOSTNAME`, então coloque um proxy que termina TLS (Caddy ou nginx) na frente de qualquer coisa alcançável pela internet.

## Backup

O diretório `data/` é todo o estado do servidor: o banco SQLite com seus arquivos auxiliares, `keys/` com uma chave por conta (0600, dentro de uma pasta 0700) e `server.secret`.

Copie o diretório com o servidor parado, ou use a API de backup do SQLite se precisar de uma cópia consistente de um servidor em uso.

**`data/server.secret` é o arquivo mais importante do conjunto.** Um único segredo HMAC assina os tokens de todas as contas. Quem o obtiver consegue criar um token válido para qualquer identidade hospedada e agir como qualquer usuário, sem deixar registro no repositório. As chaves em `data/keys/` são bem menos sensíveis: elas permitem forjar commits de uma conta, e um commit forjado falha na verificação de assinatura assim que alguém confere. Perder uma chave quebra aquela identidade de forma evidente. Vazar o server secret abre o servidor inteiro sem que ninguém perceba.

## Docker

A imagem define `PDS_DATA_DIR=/data`, `PDS_PORT=4000` e `VOLUME /data`.

```bash
docker build -t pesque .
docker run -d \
  --name pesque \
  -p 4000:4000 \
  -v pesque-data:/data \
  -e PDS_HOSTNAME=pds.example.com \
  pesque
```

Em produção, coloque o container atrás de um proxy que termina TLS e aponte `PDS_HOSTNAME` para o endereço público, senão as URLs anunciadas e o `did:web` vão dizer `localhost`.

## Uma nota sobre o did:web

A identidade vem do `did:web` e não do diretório PLC. Isso mantém o servidor autossuficiente: o documento DID é um arquivo JSON servido do seu próprio domínio.

O custo é que sua identidade é tão estável quanto o seu controle do domínio e das chaves em disco. Se o domínio expirar ou `data/keys/` for perdido, a identidade vai junto. Para um servidor em um domínio que você controla, essa troca costuma valer a pena. Só saiba o que você está aceitando.

## Licença

[WTFPL](LICENSE). Faça o que quiser com este código.