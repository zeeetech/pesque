# Changelog

## [1.9.0](https://github.com/zeeetech/pesque/compare/pesque-v1.8.2...pesque-v1.9.0) (2026-10-12)


### Features

* **web:** name the requester in the access log and log error bodies ([8227ab2](https://github.com/zeeetech/pesque/commit/8227ab2c6c4955ac453bd3136d04fbdf02308c36))


### Bug Fixes

* **oauth:** unwrap a fetched jwks_uri document into its keys ([7899693](https://github.com/zeeetech/pesque/commit/78996931985118b38b2123b663e478ccaf8d66ed))

## [1.8.2](https://github.com/zeeetech/pesque/compare/pesque-v1.8.1...pesque-v1.8.2) (2026-10-12)


### Bug Fixes

* gettext stale line extraction ([9ce5b3d](https://github.com/zeeetech/pesque/commit/9ce5b3d923a9fa8dd99dfa23ce8115d8d462c711))
* **migrate:** fetch the old PDS through the hardened client ([dd4ae05](https://github.com/zeeetech/pesque/commit/dd4ae057d67c9ce6a10477efad9e3acab6ac7e48))
* **oauth:** allow the client origin in the consent form policy ([a8d2bca](https://github.com/zeeetech/pesque/commit/a8d2bca01c5ffc5c489cff9e2e190708cd547a7f))
* **web:** lead the landing's call to action with the primary ([c3b98dd](https://github.com/zeeetech/pesque/commit/c3b98ddf201e4c20552c0b53b45474de773b3607))

## [1.8.1](https://github.com/zeeetech/pesque/compare/pesque-v1.8.0...pesque-v1.8.1) (2026-10-12)


### Bug Fixes

* nix module FOD deps hash ([230eefb](https://github.com/zeeetech/pesque/commit/230eefb657437e0916d06d8cb55f88bddf0ef647))

## [1.8.0](https://github.com/zeeetech/pesque/compare/pesque-v1.7.0...pesque-v1.8.0) (2026-10-12)


### Features

* **plc:** keep PLC operations in a file for development ([a0dc7ec](https://github.com/zeeetech/pesque/commit/a0dc7ec2fa55b15c1f345deec5e28901f0a9d8ad))
* **web:** add phoenix_html and gettext ([d978106](https://github.com/zeeetech/pesque/commit/d978106a8ae4d3c1128425f1ab3a1365ad0e3f8e))
* **web:** add the layout and the page bodies ([2697b23](https://github.com/zeeetech/pesque/commit/2697b2353675ce8fc19cd7680318837be58a7599))
* **web:** add the page stylesheet and serve the assets ([c21b1dd](https://github.com/zeeetech/pesque/commit/c21b1ddfc4484fa8fb1794b98230f2b6033ab012))
* **web:** add the self-hosted brand assets ([c37d4de](https://github.com/zeeetech/pesque/commit/c37d4de48a891f546924c2a228bf2bdb105b6333))
* **web:** move the consent page onto the shared shell ([d35b7a0](https://github.com/zeeetech/pesque/commit/d35b7a0badce25c2de6cac3fd38190c7e7a80596))
* **web:** offer signup from the landing ([c3d04c7](https://github.com/zeeetech/pesque/commit/c3d04c79ffed98e2f4001502555d1d8826443c44))
* **web:** render the browser error pages ([12ceef8](https://github.com/zeeetech/pesque/commit/12ceef8bb85fd33656768db7d7a90de9762ea209))
* **web:** serve an invite-gated signup page ([fd79e72](https://github.com/zeeetech/pesque/commit/fd79e726a75a0214ed12be5275a9c15924ac4685))
* **web:** serve the landing and handle pages by host ([51c2777](https://github.com/zeeetech/pesque/commit/51c277764c574184ec5646a637fd80d6b5db1252))


### Bug Fixes

* **web:** log a signup failure the page cannot explain ([70b6930](https://github.com/zeeetech/pesque/commit/70b6930ed2c90c944596da46b04751f9cc893a62))
* **web:** render the error pages and keep the header padded ([200fd9f](https://github.com/zeeetech/pesque/commit/200fd9f9bfd264562ccaf79388fa26b94a26e2da))

## [1.7.0](https://github.com/zeeetech/pesque/compare/pesque-v1.6.0...pesque-v1.7.0) (2026-10-12)


### Features

* **accounts:** answer handle availability and an account's invite codes ([a435184](https://github.com/zeeetech/pesque/commit/a435184cf67aa81893aef5ab1171de5e71981baf))
* **accounts:** mint and spend email and password reset codes ([0486719](https://github.com/zeeetech/pesque/commit/0486719c787a5c1d078000e6556d73a23f36d92f))
* **cli:** expose account email-token and reset-token ([09252f1](https://github.com/zeeetech/pesque/commit/09252f137d6a5123182f1ed38aa19e1ae0dcb671))
* **server:** serve handle availability, invite codes and emailConfirmed ([6188243](https://github.com/zeeetech/pesque/commit/618824302e29e86ff92348643e886079c7eb01b2))
* **server:** serve the email and password endpoints ([9071251](https://github.com/zeeetech/pesque/commit/90712517b8478486fcda042b77966831ef7a9f39))


### Bug Fixes

* **accounts:** resolve the login identifier as the login_hint check does ([c2ee422](https://github.com/zeeetech/pesque/commit/c2ee422501dec487f939fb6d5a46fda31477f061))
* **identity:** lowercase handle_domain so stored handles resolve ([640aa97](https://github.com/zeeetech/pesque/commit/640aa97b86788f52fc01f081362d80ba36363e23))

## [1.6.0](https://github.com/zeeetech/pesque/compare/pesque-v1.5.1...pesque-v1.6.0) (2026-10-12)


### Features

* **accounts:** add named app-password credentials ([2300347](https://github.com/zeeetech/pesque/commit/2300347edabdeb6372b48c8f331779bad238b767))
* **accounts:** mint, rotate and revoke app-password sessions ([2a9cee2](https://github.com/zeeetech/pesque/commit/2a9cee24b78574cae66708625f42ad8605607f94))
* **cli:** expose account app-passwords and revoke-app-password ([4ec5b98](https://github.com/zeeetech/pesque/commit/4ec5b98842ea512006366593983ee949e92b1de4))
* **cli:** expose account plc-token through the host cli ([60a9459](https://github.com/zeeetech/pesque/commit/60a9459184acc1c98e984e902c113971e17c795b))
* **config:** make the lexicon aggregator a config key ([0b64394](https://github.com/zeeetech/pesque/commit/0b643948b319c613cf6160187fabbe4a153c5678))
* **identity:** sign a hosted did:plc account's move out ([06ead21](https://github.com/zeeetech/pesque/commit/06ead21eebe355e451532ff8d27d199df4b1f9bf))
* **lexicon:** resolve permission sets from the registry or an aggregator ([d2cbf5c](https://github.com/zeeetech/pesque/commit/d2cbf5cab07a64c48b4e815da85a108fa1967e1d))
* **lexicon:** vendor the userinput.app authBasic permission set ([2557312](https://github.com/zeeetech/pesque/commit/25573127f56b01a19bbd2abd5c8de29371f14904))
* **oauth:** add the permission grammar and grant set core ([f278c8f](https://github.com/zeeetech/pesque/commit/f278c8faac88aed004011f1ef607adb40100d34e))
* **oauth:** enforce granular permissions and accept granular scopes ([28569d3](https://github.com/zeeetech/pesque/commit/28569d3f600001b5cce9dd75c0c0b4e5c52be037))
* **oauth:** map legacy session scopes onto the grant grammar ([b847556](https://github.com/zeeetech/pesque/commit/b8475567f57b2108e307cfdda3e898ccfd353fa5))
* **oauth:** resolve permission sets and store the expansion on access tokens ([9a0c11d](https://github.com/zeeetech/pesque/commit/9a0c11dfa8f6679cddb262d22f6b8de7a6f1769f))
* **oauth:** show permission sets on the consent page ([0a6468b](https://github.com/zeeetech/pesque/commit/0a6468b3abdf4cfee630d47aceb77482a1947b3c))
* **oauth:** store the granted scope and narrow it on the consent page ([4d23037](https://github.com/zeeetech/pesque/commit/4d23037510e8c5cc3169479cb97c557a32b8a952))
* **server:** serve the app-password endpoints behind the grant tiers ([274762b](https://github.com/zeeetech/pesque/commit/274762b64907d4e40d94f61327f7cf47dd0140ff))


### Bug Fixes

* **ops:** close the reviewed gaps on the write, backup and cli paths ([b5a12af](https://github.com/zeeetech/pesque/commit/b5a12af71ad78611e348870a8182fa2a5c78a249))

## [1.5.1](https://github.com/zeeetech/pesque/compare/pesque-v1.5.0...pesque-v1.5.1) (2026-10-12)


### Bug Fixes

* **ci:** build the release at its default path so the tarball finds it ([95e5c9d](https://github.com/zeeetech/pesque/commit/95e5c9d75081da6070941833e3d76caa428e2e06))
* **cli:** read the release path and data dir from the running unit ([12a1b6d](https://github.com/zeeetech/pesque/commit/12a1b6d34923b44610a6f959e8c0a931711e3da9))

## [1.5.0](https://github.com/zeeetech/pesque/compare/pesque-v1.4.0...pesque-v1.5.0) (2026-10-12)


### Features

* **cli:** add the zig host-side operations binary ([e7bf4e0](https://github.com/zeeetech/pesque/commit/e7bf4e037b9bf75d983d7173064d1abbf100621f))
* **installer:** bootstrap install.sh, release assets, and one-liner docs ([dbb6c97](https://github.com/zeeetech/pesque/commit/dbb6c9799c9203cf2d3e50179b9d65c71c2b1798))
* **metrics:** merge the token-gated metrics endpoint and monitoring stack ([27214d0](https://github.com/zeeetech/pesque/commit/27214d010189a1831aa7eeac283fc5828c46dd17))
* **metrics:** token-gated /metrics endpoint and optional monitoring stack ([6ecc35e](https://github.com/zeeetech/pesque/commit/6ecc35e2c3d8ff673337aee8db044574760428e9))
* **nix:** build the host-side cli and install it on nixos ([d3b8185](https://github.com/zeeetech/pesque/commit/d3b8185814eb3ae09f967fa3eadbce4da521da59))
* **nix:** merge the verb-based operator oneshots ([934e2e8](https://github.com/zeeetech/pesque/commit/934e2e8502fbaf4f61c3047408a22bfa13a0310e))
* **nix:** run the operator oneshots on the release verbs ([fb9c8fb](https://github.com/zeeetech/pesque/commit/fb9c8fb20fa1cf4b092593429e73173631e573e6))
* **ops:** merge tier 1 auto-update ([761772e](https://github.com/zeeetech/pesque/commit/761772e5dfcb933d515c6b2edbc60a0e6ab39d1d))
* **ops:** opt-in auto-update for compose and systemd ([93c6de1](https://github.com/zeeetech/pesque/commit/93c6de1a12b7e9df0c7b1130444ad398299f7acf))
* **ops:** the unified verb layer, backup, and config hardening ([76544de](https://github.com/zeeetech/pesque/commit/76544de47c0fc16c3c653047764a9fc4f37946de))


### Bug Fixes

* **cli:** correct the reviewed host-side bugs ([c045d6a](https://github.com/zeeetech/pesque/commit/c045d6a76fd0217b71992e93fad2b3d2af8a0c3b))
* **cli:** strip the release tarball's top-level directory on unpack ([0974c2f](https://github.com/zeeetech/pesque/commit/0974c2f784c6ce14a847f44d6a3723a51d0ede36))
* **config:** drop the trailing space on empty commented defaults ([24c77d9](https://github.com/zeeetech/pesque/commit/24c77d90fbf2a8c76b2bc9696e02383aaf8eed39))
* **config:** drop the trailing space on empty commented defaults ([06f7d9e](https://github.com/zeeetech/pesque/commit/06f7d9ee198fd5c5be98efb0ed8570fdca856ed3))
* **federation:** emit #identity during a migration ([9685cfe](https://github.com/zeeetech/pesque/commit/9685cfe55b0313d76f3fea8996c85a72c43247ad))
* **federation:** emit an empty commit when an account activates ([b56525a](https://github.com/zeeetech/pesque/commit/b56525a22330d19f541f99ee3d1e463fe2139a9a))
* **federation:** let the new PDS announce last on a migration ([479645e](https://github.com/zeeetech/pesque/commit/479645ef86de5744ce36ac38117dec2340ba8037))
* **federation:** merge the activation announcement fixes into main ([22e53cf](https://github.com/zeeetech/pesque/commit/22e53cfd0524d6237cb85ec08b261f35aacac597))
* **federation:** re-request crawl at the end of a migration ([cccf7db](https://github.com/zeeetech/pesque/commit/cccf7db51dab5b92a2aa328e8fe90308b177bfa2))
* **install:** make the bootstrap safe to re-run ([a944983](https://github.com/zeeetech/pesque/commit/a944983fa90334a84bb78dd1c28e6406e2febfb4))
* **lexicon:** log why a lexicon file was skipped ([cbbb188](https://github.com/zeeetech/pesque/commit/cbbb18855a82c9ef5213c93cea0013ccbcdabcab))
* **mix:** keep the dev --password flag out of the verb argv ([a7d9c3d](https://github.com/zeeetech/pesque/commit/a7d9c3de98cf6181b49689eb0bb4ffbcdba978ef))
* **nix:** refresh the mix deps hash after the lock prune ([76c507e](https://github.com/zeeetech/pesque/commit/76c507e3e512b2a45f3751d88f97115e1946c288))
* **repo:** never hand back a reaped repo server from ensure_started ([5346cc1](https://github.com/zeeetech/pesque/commit/5346cc116becb07d0355f1220568cb85ea2d3b49))
* **tls:** on-demand certs for path_multi handles ([378cbe6](https://github.com/zeeetech/pesque/commit/378cbe6edf27a2d8c7d0dc91a06828076c8d1046))


### Reverts

* **metrics:** drop the /metrics endpoint and the monitoring stack ([9dc7446](https://github.com/zeeetech/pesque/commit/9dc7446b83006b9a3652dc8cd8abf672ffbefb94))

## [1.4.0](https://github.com/zeeetech/pesque/compare/pesque-v1.3.3...pesque-v1.4.0) (2026-10-10)


### Features

* **migrate:** keep blobs already stored on a re-run ([f9dac75](https://github.com/zeeetech/pesque/commit/f9dac7504788c3b3cecb434f26b29a25df1439cf))
* **migrate:** report progress through the move ([84b3f9a](https://github.com/zeeetech/pesque/commit/84b3f9a6146a129a0b5296b59620344c9f7a5be9))


### Bug Fixes

* **migrate:** follow the old pds redirect on sync reads ([a4f6840](https://github.com/zeeetech/pesque/commit/a4f6840eafa0515a7bb24d09b1fcdc7174bb70b7))
* **migrate:** read every listBlobs page, not just the first ([4f0de6d](https://github.com/zeeetech/pesque/commit/4f0de6d5333c14a7d32c282d9257cf850ee71880))
* **migrate:** request the plc code with no body ([fb8628f](https://github.com/zeeetech/pesque/commit/fb8628fce8381ef289a26d2f8dd54e91a3356642))
* **migrate:** sign the plc operation in the identity namespace ([f1b73f8](https://github.com/zeeetech/pesque/commit/f1b73f830d2258a1a1db8616cd798799192ef143))

## [1.3.3](https://github.com/zeeetech/pesque/compare/pesque-v1.3.2...pesque-v1.3.3) (2026-10-10)


### Bug Fixes

* **migrate:** take the plc code without a terminal ([f477bf3](https://github.com/zeeetech/pesque/commit/f477bf3a2ee4d8adc8ba5acaf3a3b473368d70e1))
* **repo:** batch block inserts under sqlite's variable ceiling ([fbcf5e6](https://github.com/zeeetech/pesque/commit/fbcf5e62646200566626b1972b0fc09e33eeca23))

## [1.3.2](https://github.com/zeeetech/pesque/compare/pesque-v1.3.1...pesque-v1.3.2) (2026-10-10)


### Bug Fixes

* **nix:** build exqlite from source instead of fetching a NIF ([46695b2](https://github.com/zeeetech/pesque/commit/46695b2edac120ccc8b718177ebe5ea25a292ed0))

## [1.3.1](https://github.com/zeeetech/pesque/compare/pesque-v1.3.0...pesque-v1.3.1) (2026-10-10)


### Bug Fixes

* **nix:** build against the current beam override API ([a041b73](https://github.com/zeeetech/pesque/commit/a041b7345d862505380caaf40b4f9766957244c2))

## [1.3.0](https://github.com/zeeetech/pesque/compare/pesque-v1.2.1...pesque-v1.3.0) (2026-10-10)


### Features

* **nix:** build the release and run it on NixOS ([30d9d23](https://github.com/zeeetech/pesque/commit/30d9d23f1510c202fe5aba09624cc01a18d69abf))
* **scripts:** drive a container without compose ([5cf0df7](https://github.com/zeeetech/pesque/commit/5cf0df7f82bb1969ac4daf4e1adc94cede5eb784))

## [1.2.1](https://github.com/zeeetech/pesque/compare/pesque-v1.2.0...pesque-v1.2.1) (2026-10-10)


### Bug Fixes

* **identity:** branch on the server's own DID method ([e38f5d4](https://github.com/zeeetech/pesque/commit/e38f5d4ec03128b146b571becd4387a6e0f4778e))

## [1.2.0](https://github.com/zeeetech/pesque/compare/pesque-v1.1.2...pesque-v1.2.0) (2026-10-09)


### Features

* **doctor:** check the relay's crawl status ([dd7af8d](https://github.com/zeeetech/pesque/commit/dd7af8dcede4e1ad114aae820c14e4e803169174))
* **doctor:** report the config file in effect ([45e25df](https://github.com/zeeetech/pesque/commit/45e25df501e2e101b19cd6e705ab5f2a7ac32f73))


### Bug Fixes

* **deploy:** set PDS_CRAWLER in the compose ([0dc00a8](https://github.com/zeeetech/pesque/commit/0dc00a86d996d466a9fc0c92107818a9f1f70e6b))

## [1.1.2](https://github.com/zeeetech/pesque/compare/pesque-v1.1.1...pesque-v1.1.2) (2026-10-07)


### Bug Fixes

* **deploy:** correct the GHCR image path ([a15b46f](https://github.com/zeeetech/pesque/commit/a15b46f1af4681db61f017cb203411c0af610d3b))
* **repo:** add $type to applyWrites results ([a3f2e88](https://github.com/zeeetech/pesque/commit/a3f2e881d85ba506774f17b93780f6dfc3419b60))

## [1.1.1](https://github.com/zeeetech/pesque/compare/pesque-v1.1.0...pesque-v1.1.1) (2026-10-07)


### Bug Fixes

* **cors:** echo the preflight's requested headers ([0e4eaff](https://github.com/zeeetech/pesque/commit/0e4eaff9e259748d404dd9acd355d3ac84cf7d81))
* **lexicon:** resolve the vendored directory at runtime ([1753796](https://github.com/zeeetech/pesque/commit/17537965cc64d3770c60fe2ca643b6f74c45ebe5))
* **oauth:** pass max_body_size as a request option ([e77af45](https://github.com/zeeetech/pesque/commit/e77af4594cd9ce7933eb30d8c98ba726200b2553))

## [1.1.0](https://github.com/zeeetech/pesque/compare/pesque-v1.0.0...pesque-v1.1.0) (2026-10-07)


### Features

* **deploy:** one-command setup, prebuilt image, human output ([3075656](https://github.com/zeeetech/pesque/commit/3075656be2f282499a92280875f71955538177ba))
* **xrpc:** forward proxied calls and serve preferences ([c271ee0](https://github.com/zeeetech/pesque/commit/c271ee05445cfd0e2df16f5c1e0285019ae3a0d9))


### Bug Fixes

* correctly start app supervision tree inside container (release) ([2ac0768](https://github.com/zeeetech/pesque/commit/2ac0768ee1282c7b7c8d199df0cc75d1adfeb1cf))

## 1.0.0 (2026-10-07)


### Features

* **accounts:** per-user signing keys and path dids ([08635a0](https://github.com/zeeetech/pesque/commit/08635a0f15fd2e9bd219fcc49fd1a927af923aa7))
* **auth:** session management ([0f5f5c6](https://github.com/zeeetech/pesque/commit/0f5f5c63e7f4f7efb13768e1fdb34b735005da9e))
* **blobs:** add blob storage and both blob endpoints ([a3fd295](https://github.com/zeeetech/pesque/commit/a3fd2950ef5ab0ba5f5a7bab19a165a5b42c2560))
* **boot:** zero-config bedrock ([b973e24](https://github.com/zeeetech/pesque/commit/b973e24b06ba6ad86b38778003a11cf52bcc08e2))
* **cbor:** dag-cbor and cids ([771c242](https://github.com/zeeetech/pesque/commit/771c242cf5d603989c2ad23cdb40f8bbb04ba26e))
* **cli:** keep create_account off the endpoint and explain a short password ([14c2194](https://github.com/zeeetech/pesque/commit/14c219447e457c97154550a1b0cb0db8a2bcb8b2))
* **config:** a pesque.conf file under the environment ([fa10891](https://github.com/zeeetech/pesque/commit/fa10891871fe648a0aac05cd3538d8e5542bb0cc))
* **config:** derive the DID method from the mode and add a serve switch ([8c9fb1e](https://github.com/zeeetech/pesque/commit/8c9fb1ec7af7ce173c69715117f702b6972da7dc))
* **config:** publish policy documents only when the operator sets them ([ec502c3](https://github.com/zeeetech/pesque/commit/ec502c3e5104f9624098697f925fd2cf52b90451))
* **docker:** compose, Caddy and a setup wrapper ([4ad80de](https://github.com/zeeetech/pesque/commit/4ad80defedbe87704af9901f7c0ae113b6a1dc2a))
* **docker:** run migrations through the wrapper ([9e6e26c](https://github.com/zeeetech/pesque/commit/9e6e26ce68a79f51f8aa6ce78a252cf5c03e91ab))
* **doctor:** a federation preflight and boot warnings ([3159216](https://github.com/zeeetech/pesque/commit/315921641c406421c2cc3a0bba334f4cbf43f6f0))
* **firehose:** honest tooBig, a #sync recovery frame, and commit prev chaining ([0859b59](https://github.com/zeeetech/pesque/commit/0859b598ccc0d9f5f899557b560439095ae016f2))
* **firehose:** identity and account frames, invite codes that follow the spec ([1576190](https://github.com/zeeetech/pesque/commit/1576190d1c1122914660b90b100f5e7402e8ab27))
* **firehose:** prevData and per-op prev for the inductive firehose ([84863cb](https://github.com/zeeetech/pesque/commit/84863cb95aae7c38004e33b97afaa7b8cf2f9213))
* **identity:** did:web local resolution ([58450d1](https://github.com/zeeetech/pesque/commit/58450d101f6fb6ef85c0c889f5b3f9ca7e6e8524))
* **identity:** opt-in did:plc, and announce the server to a relay ([233e11a](https://github.com/zeeetech/pesque/commit/233e11a457338681257399bdc4cdc35f52bfe93f))
* **identity:** resolve handles through DNS TXT and the well-known document ([f5d93ac](https://github.com/zeeetech/pesque/commit/f5d93ace8f5885f7a3a042cff6474706f9cad239))
* **identity:** support did:plc under conformant_single ([9d35605](https://github.com/zeeetech/pesque/commit/9d356051d7a9327fb756223d753bf9c484480d62))
* **identity:** verify a claimed handle by resolving it ([cafc922](https://github.com/zeeetech/pesque/commit/cafc9229656863c77af828c5267ca37dc8d6281d))
* **lexicon:** validate records against a vendored lexicon set ([0b45197](https://github.com/zeeetech/pesque/commit/0b45197d29a14c234da9b67f008054d18255adbf))
* **migrate:** a task that moves an account onto this server ([82403fa](https://github.com/zeeetech/pesque/commit/82403fad76a83cb78071b8455e05347621600b2f))
* **migration:** the endpoints that let an existing account move here ([099549b](https://github.com/zeeetech/pesque/commit/099549b784ea813da0a42b5fbfceb7b952cbdb53))
* **migration:** the import half of account migration ([70ac80c](https://github.com/zeeetech/pesque/commit/70ac80cbcc8d9073583267edb79671b72b934a99))
* **oauth:** accept OAuth tokens on the XRPC endpoints ([9c80f0f](https://github.com/zeeetech/pesque/commit/9c80f0fbbe3883bff0155563eba6feaf90e84458))
* **oauth:** an ATProto OAuth authorization server ([22584c1](https://github.com/zeeetech/pesque/commit/22584c17842b2d649263bc2a1d4867c2a7b1a838))
* **ops:** make the health check probe the database and log what matters ([3ba3946](https://github.com/zeeetech/pesque/commit/3ba3946af7d595dae38343e3ef731af9066d502a))
* **repo:** applyWrites, and service auth tokens signed with the account key ([60105cb](https://github.com/zeeetech/pesque/commit/60105cbb79967cf4d5e9cbeeed20658a3321f422))
* **repo:** check records against their lexicon before committing ([3e439ea](https://github.com/zeeetech/pesque/commit/3e439ea006d027784dd623519dc605d6c7c85430))
* **repo:** mst and local repo writes ([1328352](https://github.com/zeeetech/pesque/commit/132835249b0120b9251b345e86389554c499f41b))
* **repo:** update the MST incrementally instead of rebuilding it ([333725c](https://github.com/zeeetech/pesque/commit/333725c2e8c8533d8221a80fc8cf49f34b98bbf5))
* **server:** answer describeServer and checkAccountStatus ([ffb5a2a](https://github.com/zeeetech/pesque/commit/ffb5a2ac42a47e8484f700a12a7cff99ee40f13f))
* **server:** updateHandle and the two step account deletion ([0bd239f](https://github.com/zeeetech/pesque/commit/0bd239f7b6f57a0e112f5ef3db8dc57ecc31a4c3))
* **sync:** firehose and car ([9296afd](https://github.com/zeeetech/pesque/commit/9296afd26541880acafe408a8c09d8d07fd5be29))
* **sync:** getBlocks, sync getRecord, and account deactivation ([15bd356](https://github.com/zeeetech/pesque/commit/15bd3560c61688ba707f1a4352cfb4c4110d48e0))
* **sync:** getRepoStatus, listRepos, record versions, retention and block GC ([65f9106](https://github.com/zeeetech/pesque/commit/65f91065816f9187ea2ea4a111f351c90a54f0ab))
* **sync:** stream getRepo and cap blob uploads at the enforced limit ([9d08699](https://github.com/zeeetech/pesque/commit/9d08699d0264aae388e05226f1932de8ec85a360))
* **unicode:** add UAX [#29](https://github.com/zeeetech/pesque/issues/29) grapheme segmentation ([74b693b](https://github.com/zeeetech/pesque/commit/74b693b4d95ddf9a35faa064da995a55533fdc9b))
* **web:** log each request ([5998ccf](https://github.com/zeeetech/pesque/commit/5998ccf5f115b0105fb661d0c04220c1561a4236))
* **web:** rate limit the endpoints the spec puts limits on ([ad41b0d](https://github.com/zeeetech/pesque/commit/ad41b0df8a5fcbe76b5965aed8e71d263c8e67e1))


### Bug Fixes

* **accounts:** avoid persistent_term.put_new and explain a refused handle ([e94173c](https://github.com/zeeetech/pesque/commit/e94173ce8fedb5afadef7546a886013bde600ebb))
* **accounts:** gate the deletion password verify behind the argon2 permit ([33664d1](https://github.com/zeeetech/pesque/commit/33664d13e3fb124c4bf50b0b3681ef3932817679))
* **accounts:** refuse handles and emails that collide as identifiers ([6d1c6d6](https://github.com/zeeetech/pesque/commit/6d1c6d61a8ba6a340a1c8d64c560eca71e83ce78))
* **accounts:** reject a missing email instead of raising ([2324001](https://github.com/zeeetech/pesque/commit/23240014bc9541b65668b81dfc86cd8c9a4077ba))
* **accounts:** resolve an account by the identifier it was stored under ([c5a7e35](https://github.com/zeeetech/pesque/commit/c5a7e35df7ac547cfbe9606d3d15ff94d9d854c2))
* **auth:** authorize writes by account, serve any local repo ([b72755f](https://github.com/zeeetech/pesque/commit/b72755f819a2cbced99de53f59cb0db4f39f0788))
* **auth:** gate invite-code minting, bound argon2 cost, close the login oracle ([a22c456](https://github.com/zeeetech/pesque/commit/a22c456e4568c135886df6ecd63ea3dfc593e511))
* **blobs:** answer a reason a failed write can be mapped from ([d32b15a](https://github.com/zeeetech/pesque/commit/d32b15ad9801910518efec4ba12402dd4b539482))
* **cli:** read the password through the group leader, not as a prompt ([8ec0a43](https://github.com/zeeetech/pesque/commit/8ec0a437b655ef546f58a8f4632daa3250c05668))
* **did:** resolve local identifiers to a canonical did ([3537f24](https://github.com/zeeetech/pesque/commit/3537f24efe3736c24a434bf079c365baa0d96694))
* **did:** resolve the bare server handle in conformant_single ([833bbc3](https://github.com/zeeetech/pesque/commit/833bbc34606fa96f62c1418b4163eac7d45550a2))
* **firehose:** an honest truncated replay, a gapless connect, and refused client frames ([19a113a](https://github.com/zeeetech/pesque/commit/19a113ae9d0657b49423d276658debddb8c088e6))
* **lexicon:** resolve union variants, count bytes, honour nullable and closed ([ab35ebc](https://github.com/zeeetech/pesque/commit/ab35ebc13cdcabea4f4e1a4e9dc3a93b4bb3a65a))
* make a commit transaction lock first and roll back instead of raising ([03f3a2a](https://github.com/zeeetech/pesque/commit/03f3a2aafbadfcae95589807d9b8c70775594e04))
* **mix:** provision accounts without binding the port ([d88a7c1](https://github.com/zeeetech/pesque/commit/d88a7c1e8ec08e2bf48459d5a8f54a816c26812a))
* **oauth:** resolve client metadata hosts instead of failing every fetch ([f6a8082](https://github.com/zeeetech/pesque/commit/f6a8082a9947b2b0b4db2647666d19685e4475a8))
* **protocol:** harden decoders and memoize MST depth ([f3c76e9](https://github.com/zeeetech/pesque/commit/f3c76e9d07b696ae47b265bf07952d68531ad8ad))
* **rate_limit:** bound key material, key reads on their account, cap the table ([a3017f1](https://github.com/zeeetech/pesque/commit/a3017f10932dc5c33d4889adfeeaa1ea6f71b0b4))
* **records:** turn away a value DAG-CBOR cannot encode ([4fb54af](https://github.com/zeeetech/pesque/commit/4fb54af6cc379b340cf13b67b62c8f2440ae9631))
* **repo:** retry a genesis that rolls back instead of swallowing it ([ffc9117](https://github.com/zeeetech/pesque/commit/ffc91175672e842b78726eec850529d3929c679d))
* **repo:** scope blocks by did, assign event seq in db ([6606e97](https://github.com/zeeetech/pesque/commit/6606e977eb04684b74ead0e9540d9b8d055cd31b))
* **server:** atomic refresh rotation, single-insert events, cycle guard on refs ([e8f6581](https://github.com/zeeetech/pesque/commit/e8f6581455e348ffb33b12928585a997ad205060))
* **tid:** stop claiming monotonicity next/2 does not provide ([0a8f760](https://github.com/zeeetech/pesque/commit/0a8f76089bf7f80431ec827d4e9bf8de9cdf2fa3))
* use the correct config option for bandit websocket ([60c95ed](https://github.com/zeeetech/pesque/commit/60c95ed511e31cc92d24905cc8c376539a325f05))
* **web:** enforce rate limits, truthful error bodies, firehose closes on bad cursor ([702b9c1](https://github.com/zeeetech/pesque/commit/702b9c131116d9da067c736ef23d4db52926fec9))
* **web:** meter the account routes and stop the firehose tests poisoning each other ([75fbcad](https://github.com/zeeetech/pesque/commit/75fbcad0a9858988198f33acaeef6754e06a8212))
* wire the audit fixes together and close the gaps between them ([b945b67](https://github.com/zeeetech/pesque/commit/b945b67aece2843f2623e189811708d2855c7da2))


### Performance Improvements

* **lexicon:** resolve record schemas once, not once per write ([6e0f3a0](https://github.com/zeeetech/pesque/commit/6e0f3a09bd1638779a9a189cb049fb359c7b2ef9))
