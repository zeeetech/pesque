# pesque

[English](README.md) | [Português (BR)](README.pt-BR.md)

![CI](https://github.com/zeeetech/pesque/actions/workflows/ci.yml/badge.svg)
![License: WTFPL](https://img.shields.io/badge/license-WTFPL-blue.svg)
![Elixir](https://img.shields.io/badge/elixir-1.20%20%7C%20OTP%2029-purple.svg)

Oi! Se você quer operar um PDS seu no ATProto, o Pesque é um servidor em
Elixir para criar contas, assinar repositórios e servir dados públicos,
blobs e firehose. O nome lembra PDS e faz o convite: “vai pescar”.

## Antes de começar

O servidor guarda estado em um SQLite e num diretório de blobs; não há
cluster. Ele atende uma ou poucas contas, ou uma comunidade pequena, não
hospedagem multi-tenant agressiva. Não inclui painel administrativo,
assistente de configuração, TLS ou Caddy. Proxy reverso e certificados ficam
com quem opera.

Em produção, há dois caminhos suportados: o bundle Docker Compose e o módulo
NixOS, que executam a mesma imagem. O guia de
[instalação NixOS](docs/installation.md#nixos) tem os detalhes. Para Compose,
baixe o bundle e o `SHA256SUMS` do
[release mais recente](https://github.com/zeeetech/pesque/releases/latest):

```bash
sha256sum -c SHA256SUMS
tar -xzf pesque-compose-<version>.tar.gz && cd pesque
./pesque init
$EDITOR pesque.conf                  # ajuste hostname público e esquema da URL
docker compose up --detach --wait
./pesque account create --handle pds.example.com --email alice@example.com
```

A primeira conta usa `single`, o modo padrão. O registro é fechado por padrão:
cadastros pelo navegador precisam de convite, a menos que você o abra, mas o
CLI permite criar contas diretamente. Cadastro pelo navegador e migração exigem
`multi`; `crawler` permite anunciar o servidor a relays.

## Se a ideia é desenvolver

Rodar da fonte serve para desenvolvimento, não é um caminho suportado de
implantação. Você precisa de Elixir 1.19+ com OTP 28+ e um toolchain de C:

```bash
mix deps.get
cat > pesque.conf <<'EOF'
url_scheme = http
hostname = localhost
port = 4000
data_dir = data
EOF
mix run --no-start -e 'Enum.each(Pesque.Config.source_config!(), fn {k, v} -> Application.put_env(:pesque, k, v) end); Pesque.Release.prepare()'
mix phx.server
curl http://localhost:4000/xrpc/_health
```

## No dia a dia

O bundle também traz comandos para diagnóstico e manutenção:

```bash
./pesque doctor
./pesque backup
./pesque migrate --old-pds https://bsky.social \
  --handle alice.example.com --email alice@example.com
```

O comando de migração só vale para instalações em `multi`. Os guias de
[instalação](docs/installation.md) e [operação](docs/operations.md) cobrem
configuração, contas, backup e restauração, migração, atualizações e limites.
Eles são mantidos em inglês. Para contribuir, consulte
[CONTRIBUTING.md](CONTRIBUTING.md), que explica o setup e o gate `mix precommit`.

## Licença

[WTFPL](LICENSE).
