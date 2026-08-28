# Roadmap Keryx IBD v2

Mise à jour : 2026-08-28

## Base figée

- Base officielle figée : Keryx v1.5.5
- Commit officiel de base : `bb408d54ca3992f7f9f4e269507f7603c234d24d`
- Branche de base immuable : `ibd-v2-base-v1.5.5`
- Branche d’intégration validée : `ibd-v2-integrate-v1.5.5`
- Branche active Phase 3 : `ibd-v2-phase3-persistent-state`
- Baseline canonique RUN A : 95,17 minutes sur la machine de référence
- IBD v2 reste désactivé par défaut et s’active explicitement avec `KERYX_IBD_V2=1`
- Politique de certification : runner local uniquement, `[self-hosted, Windows, X64]`

## Phase 0 — Baseline reproductible — TERMINÉE

- [x] Figer la base source officielle v1.5.5.
- [x] Intégrer l’historique IBD v2 sans modifier les branches de référence immuables.
- [x] Valider la compatibilité des zones sensibles upstream : PoM, SIMD, AArch64/NEON, stockage, base de données et keryxd.
- [x] Produire et valider le collecteur Windows canonique RUN A.
- [x] Exécuter une baseline mainnet propre avec les paramètres Keryx par défaut.
- [x] Figer le rapport et les métriques de baseline.
- [x] Identifier l’attente peer comme principal goulot PoM/body-sync.

Aucune optimisation de performance ne doit redéfinir cette baseline.

## Phase 3 — État IBD persistant et reprise après crash — ACTIVE / TRÈS AVANCÉE

### 3A. Fondation des checkpoints durables — TERMINÉE / CERTIFIÉE CI

- [x] Format de checkpoint versionné avec magic/version/longueur/checksum.
- [x] Remplacement atomique du checkpoint.
- [x] Liaison au réseau/genesis.
- [x] Liaison au pruning point.
- [x] États indépendants : Headers, Pruning, UTXO, Service State, PoM, Bodies.
- [x] Le checkpoint ne peut jamais remplacer la vérité consensus/base de données.
- [x] Rejet des checkpoints tronqués.
- [x] Rejet des checkpoints corrompus/checksum invalide.
- [x] Rejet des versions non supportées.
- [x] Rejet d’un checkpoint appartenant à un autre genesis/réseau.
- [x] Rejet des pruning points périmés.
- [x] Rejet des ensembles de stages/progressions sémantiquement invalides.
- [x] Rejet des headers de checkpoint trop courts/tronqués.

### 3B. Recovery durable du Service State — IMPLÉMENTÉE / CERTIFIÉE CI / TEST RÉEL EN ATTENTE

- [x] Spool Service State durable.
- [x] Ordonnancement fsync avant progression du checkpoint.
- [x] Ancre de reprise curseur + fingerprint de la ligne précédente.
- [x] Réconciliation d’un checkpoint en retard à partir du spool réellement durable.
- [x] Replay local d’un état Verified sans nouveau téléchargement réseau.
- [x] Import Service State avec sémantique atomique RocksDB WriteBatch.
- [x] Un état Committed n’est pas rejoué inutilement.
- [x] Fault points déterministes :
  - `service-state-after-spool-fsync`
  - `service-state-after-checkpoint`
  - `service-state-after-verified`
  - `service-state-after-import`
- [ ] Exécuter la matrice réelle mainnet crash/restart et archiver les preuves.

### 3C. Recovery durable UTXO — IMPLÉMENTÉE / CERTIFIÉE CI / TEST RÉEL EN ATTENTE

- [x] Cycle UTXO persistant : NotStarted -> Downloading -> Verified -> Committed.
- [x] Conservation de l’état RocksDB UTXO partiel réellement durable après crash.
- [x] Reconstruction au redémarrage du nombre d’UTXO durables et du MuHash depuis RocksDB.
- [x] Réconciliation de la progression du checkpoint depuis RocksDB au lieu de faire confiance à des métadonnées potentiellement en avance.
- [x] Reprise avec les peers incapables de seek : drainage du préfixe renvoyé jusqu’à l’ancre durable exacte.
- [x] Vérification de la valeur de l’ancre avant acceptation du suffixe restant.
- [x] Vérification cryptographique finale du préfixe reconstruit + nouveau suffixe.
- [x] Un état UTXO Verified peut rejouer l’import final localement sans retélécharger le snapshot.
- [x] L’import final du pruning point possède un test de régression de double-import idempotent.
- [x] Service State est armé avant d’exposer l’UTXO comme stable.
- [x] Fault points déterministes :
  - `utxo-after-clear`
  - `utxo-after-checkpoint`
  - `utxo-after-chunk-commit`
  - `utxo-after-verified`
  - `utxo-after-import`
  - `utxo-after-committed`
- [ ] Exécuter la matrice réelle mainnet crash/restart et archiver les preuves.

### 3D. Package final certifié pour tests réels — TERMINÉ

Gate Windows local permanent : `33182774771` — GREEN.

HEAD certifié du package :

`5bb59c04a0fb7c62d870475220822c88a08c93e8`

Commit fonctionnel final UTXO inclus dans ce HEAD :

`d921b29d108cf5d3cb7d4f53addbe81fd0502345`

Artefact :

`keryx-ibd-v2-phase3-realtest-5bb59c04a0fb7c62d870475220822c88a08c93e8`

SHA-256 du ZIP :

`e1533479c26f62228fb9bc4fd156f47c412be5909db109fc3ad1628c86e13a7b`

SHA-256 de `keryxd.exe` :

`2e17fb843758b65aea6df53edffa779c8ac57e1e8861903315f59077d7fbd752`

Le digest du ZIP a été vérifié indépendamment contre le digest GitHub et le digest de l’exécutable a été vérifié indépendamment contre le manifest interne du build.

### 3E. Frontières de recovery durable PoM et block bodies — PROCHAINE PRIORITÉ DE DÉVELOPPEMENT HORS-LIGNE

État actuel : le schéma de checkpoint contient déjà les stages indépendants `Pom` et `Bodies`, et le chemin IBD existant sait déjà recalculer les bodies manquants à partir du consensus. En revanche, Phase 3 ne possède pas encore pour PoM/Bodies le même coordinateur de recovery durable et la même certification de frontières de crash que pour UTXO et Service State.

Travail nécessaire avant de déclarer Phase 3 terminée :

- [ ] Définir la sémantique minimale de checkpoint PoM/body.
- [ ] Ne jamais enregistrer un progrès PoM/body avant que l’état correspondant soit durable dans consensus/base de données.
- [ ] Persister une cible body-sync sûre uniquement si elle peut être reconstruite depuis le consensus local après redémarrage.
- [ ] Recalculer les bodies réellement manquants depuis le consensus au lieu de faire confiance à une liste persistée.
- [ ] Déterminer si PoM nécessite réellement un curseur durable séparé ou si son état peut être entièrement dérivé des blocs/proofs durables.
- [ ] Ajouter des fault points hard-crash déterministes aux frontières choisies.
- [ ] Ajouter des tests unitaires/intégration prouvant qu’un redémarrage ne saute jamais un body/proof non durable.
- [ ] Ajouter ces tests au gate Windows local permanent Phase 3.

### 3F. Campagne réelle crash/restart Phase 3 — BLOQUÉE UNIQUEMENT PAR LA DISPONIBILITÉ DES NODES

Quand les nodes de test pourront tourner :

1. Arrêter tout autre processus `keryxd`.
2. Utiliser uniquement des datadirs dédiés Phase 3 ; ne jamais toucher au datadir historique.
3. Exécuter tous les crash points Service State.
4. Exécuter tous les crash points UTXO.
5. Réutiliser un clone à froid d’un état UTXO Verified pour `utxo-after-import` et `utxo-after-committed`, afin d’éviter de retélécharger plusieurs fois le gros snapshot UTXO.
6. Exécuter les crash points PoM/body après implémentation de 3E.
7. Archiver logs, checkpoints, hashes, comportement au restart et résultat final de sync pour chaque test.
8. Phase 3 ne devient GREEN que si chaque crash reprend sans perte silencieuse, sans progression de confiance avant durabilité, sans état final ambigu et sans redémarrage complet inutile.

## Phase 1 — Scheduler et budgets adaptatifs — VERROUILLÉE JUSQU’À PHASE 3 GREEN

Après Phase 3 :

- [ ] Scheduler conscient des stages.
- [ ] Budgets adaptatifs de travaux en vol.
- [ ] Backpressure selon la pression validation/stockage.
- [ ] Mémoire bornée.
- [ ] Aucun changement des règles de vérification consensus.
- [ ] Mesurer CPU, RAM, disque, réseau et attente peer.

Pas encore de peer racing/multi-peer sans revue séparée.

## Phase 2 — Améliorations throughput/download — VERROUILLÉE JUSQU’À SÉCURISATION DE PHASE 1

- [ ] Réduire l’attente peer PoM/body identifiée par RUN A.
- [ ] Pipeliner plus agressivement réception réseau et validation locale lorsque c’est sûr.
- [ ] Améliorer le batching sans déplacer les frontières de durabilité avant le stockage réel.
- [ ] Évaluer la découverte des capacités des peers.
- [ ] Seulement ensuite évaluer le scheduling multi-peer/chunks.
- [ ] Les miroirs HTTP/transports alternatifs restent optionnels et ne deviennent jamais des ancres de confiance.

## Benchmark comparatif final

Répéter la méthodologie canonique RUN A avec IBD v2 activé :

- Datadir neuf et vide.
- Paramètres node comparables par défaut.
- Même machine et même méthodologie lorsque possible.
- Échantillonnage ressources toutes les 5 secondes.
- Métriques par stage activées.
- Mesurer temps total de sync, durée de chaque phase, CPU/RAM/disque/réseau, peer wait, throughput, stalls et coût des reprises.
- Comparer à RUN A figé = 95,17 minutes.

## Gates avant activation

IBD v2 doit rester opt-in tant que tout ceci n’est pas GREEN :

- [ ] Preuves réelles Phase 3 crash/restart.
- [ ] Recovery durable PoM/body.
- [ ] Sécurité du scheduler.
- [ ] Correctness des optimisations throughput.
- [ ] Benchmark comparatif.
- [ ] Gate de compatibilité upstream après rebase/mise à jour finale.
- [ ] Aucune divergence des règles consensus ou de sérialisation.

## Règle d’architecture non négociable

La source distante n’est jamais digne de confiance. Chaque peer, futur miroir ou transport alternatif ne fournit que des octets. Keryx vérifie localement les engagements cryptographiques, les règles consensus et l’état durable avant de valider la progression.
