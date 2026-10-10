# Changelog

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
