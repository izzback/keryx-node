# Roadmap Keryx IBD v2

Mise à jour : 2026-08-28

> Ce document suit l’ordre canonique du projet. La branche technique actuelle conserve son nom historique `ibd-v2-phase3-persistent-state`, mais ce nom de branche ne redéfinit pas la numérotation de la roadmap.

## Légende des statuts

⬜ Planifié
🟨 En cours
🧪 En test
✅ Validé
⛔ Bloqué

---

# Objectif

Améliorer l’Initial Block Download de Keryx afin qu’un nouveau node puisse se synchroniser :

- plus rapidement
- avec moins de pression sur la RAM
- avec moins de lectures inutiles en base de données
- sans recommencer de gros téléchargements après une déconnexion
- sans dépendre d’un serveur central de confiance
- sans nécessiter de ports entrants ouverts
- tout en conservant une vérification locale complète

Principe fondamental :

Le transport peut venir de n’importe qui.
La validation doit toujours rester locale.

Base active figée pour les comparaisons : Keryx v1.5.5, commit `bb408d54ca3992f7f9f4e269507f7603c234d24d`.
Baseline canonique RUN A : **95,17 minutes**.

---

# Phase 0 — Instrumentation de l’IBD

Statut global : 🟨 Très avancée

✅ Ajouter des métriques détaillées pour les principales étapes de l’IBD
✅ Mesurer le débit de téléchargement des headers
✅ Mesurer le débit de téléchargement des bodies
✅ Mesurer le débit des preuves PoM
✅ Mesurer le débit de téléchargement de l’UTXO
✅ Mesurer le débit du Service State
✅ Mesurer la bande passante réseau utilisée
🟨 Mesurer le temps CPU de validation avec une granularité suffisamment fine
⬜ Mesurer directement les latences de lecture/écriture RocksDB par opération IBD
✅ Mesurer le temps d’attente / d’inactivité des peers
✅ Mesurer le temps passé dans les principales étapes de l’IBD

Métriques cibles :

- headers/sec
- blocs/sec
- preuves PoM/sec
- UTXOs/sec
- lignes Service State/sec
- MB/sec
- temps CPU de validation par bloc
- latence RocksDB
- temps d’inactivité peer
- durée totale de l’IBD

Résultat RUN A important : le PoM/body-sync est très fortement limité par le peer wait.

Objectif :

Identifier les vrais goulets d’étranglement avant de modifier le comportement du protocole.

Aucune modification du consensus.

---

# Phase 1 — Synchronisation resumable du Service State

Statut global : 🧪 Implémentée et certifiée CI, tests mainnet réels en attente

✅ Ajouter des identifiants de chunks / curseurs
✅ Ajouter un stockage temporaire durable pour le Service State
✅ Persister la progression du téléchargement
✅ Persister le curseur courant
✅ Persister l’avancement de la vérification (`DOWNLOADING` / `VERIFIED` / `COMMITTED`)
🧪 Supporter la reprise après crash du node
🧪 Supporter la reprise après mise à jour du node
🧪 Supporter la reprise après déconnexion d’un peer
🧪 Supporter la reprise depuis un autre peer
✅ Vérifier le commitment final du Service State
✅ Commit atomique de l’état vérifié via RocksDB WriteBatch

Implémentation déjà certifiée :

- spool durable
- fsync avant progression du checkpoint
- curseur + fingerprint de la ligne précédente
- replay local d’un état `VERIFIED`
- aucun redownload réseau nécessaire pour le replay `VERIFIED`
- fault points :
  - `service-state-after-spool-fsync`
  - `service-state-after-checkpoint`
  - `service-state-after-verified`
  - `service-state-after-import`

Reste à valider sur mainnet : la matrice réelle crash/restart, changement de peer et reprise après coupure réseau.

Objectif :

Ne jamais recommencer un gros téléchargement de Service State depuis zéro sauf si le pruning point lui-même devient invalide.

Aucune modification des règles de consensus.

---

# Phase 2 — Synchronisation resumable de l’état UTXO

Statut global : 🧪 Implémentée et certifiée CI, tests mainnet réels en attente

🟨 Ajouter des curseurs déterministes pour les chunks UTXO

Note : pour rester compatible avec les peers v1.5.5 actuels, la première implémentation utilise une ancre déterministe sur le dernier outpoint durable. Un peer incapable de seek renvoie le préfixe, qui est vérifié/drainé jusqu’à cette ancre. Un vrai curseur réseau pourra être ajouté plus tard sans perdre cette compatibilité.

✅ Utiliser un stockage UTXO temporaire/durable

Note : l’implémentation réutilise le pruning UTXO RocksDB existant plutôt que de créer une seconde base redondante.

✅ Persister les chunks terminés avec un WriteBatch atomique par chunk
✅ Persister les métadonnées de progression
🧪 Reprendre après redémarrage
🧪 Reprendre après coupure réseau
🧪 Reprendre depuis un autre peer
✅ Vérifier le commitment complet de l’UTXO en reconstruisant le MuHash
🧪 Basculer vers l’état UTXO vérifié/committed avec reprise sûre autour de la transition

Implémentation déjà certifiée :

- reconstruction du préfixe durable depuis RocksDB
- reconstruction MuHash au restart
- skip du préfixe réseau déjà durable
- append uniquement du suffixe manquant
- replay local après `VERIFIED`
- double-import final testé comme idempotent
- fault points :
  - `utxo-after-clear`
  - `utxo-after-checkpoint`
  - `utxo-after-chunk-commit`
  - `utxo-after-verified`
  - `utxo-after-import`
  - `utxo-after-committed`

Objectif :

Éviter de retélécharger plusieurs gigaoctets d’état inutilement.

---

# Phase 3 — Suivi indépendant des états IBD

Statut global : 🟨 En cours

🟨 Suivre l’état Headers indépendamment
🟨 Suivre l’état Pruning indépendamment
✅ Suivre l’état UTXO indépendamment
✅ Suivre le Service State indépendamment
🟨 Suivre l’état PoM indépendamment
🟨 Suivre l’état Bodies indépendamment

États implémentés dans le schéma :

NOT_STARTED
DOWNLOADING
VERIFIED
COMMITTED

Le format de checkpoint durable est déjà :

- versionné
- protégé par checksum cryptographique
- lié au genesis/réseau
- lié au pruning point
- écrit atomiquement
- capable de rejeter corruption, troncature, version inconnue et checkpoint périmé

UTXO et Service State utilisent déjà réellement ces états pour leur recovery.
Headers, Pruning, PoM et Bodies doivent encore être raccordés au même niveau de recovery effectif avant de considérer la Phase 3 comme ✅.

Objectif :

Rendre l’IBD récupérable au lieu de considérer la synchronisation comme une seule grosse opération tout-ou-rien.

---

# Phase 4 — Batching base de données et validation

Statut global : 🟨 Prochaine priorité de développement hors-ligne

⬜ Regrouper les recherches de headers en base
⬜ Regrouper les recherches de statut des blocs
⬜ Regrouper les requêtes sur les bodies manquants
⬜ Utiliser RocksDB `multi_get` lorsque pertinent
⬜ Réduire les appels async répétés au consensus
⬜ Pipeline entre téléchargement réseau et validation
⬜ Pipeline entre validation et écritures en base
⬜ Ajuster dynamiquement la taille des batches IBD
⬜ Ajouter du backpressure sur les files

Travail précurseur déjà effectué :

✅ Import Service State regroupé en RocksDB WriteBatch atomique
✅ Écriture UTXO regroupée en WriteBatch atomique par chunk

Ces deux optimisations ne remplacent pas les tâches Phase 4 ci-dessus ; elles constituent seulement une base sûre.

Objectif :

Réduire les accès aléatoires à la base et limiter les périodes d’inactivité CPU/réseau.

Aucune modification du consensus.

---

# Phase 5 — IBD compatible PoM

Statut global : ⬜ Planifiée

⬜ Détecter si un peer peut fournir les anciennes preuves PoM
⬜ Suivre le plus ancien DAA PoM disponible par peer
⬜ Suivre la profondeur de rétention des preuves PoM
⬜ Éviter de sélectionner des peers incapables pour l’IBD historique
⬜ Réessayer les preuves PoM manquantes sans rejeter des bodies valides
⬜ Permettre de demander les preuves PoM indépendamment des bodies
⬜ Persister la progression des preuves PoM téléchargées
✅ Ajouter des métriques de vérification/transfert PoM historique

Objectif :

Un peer possédant le tip de la blockchain ne doit pas automatiquement être considéré comme capable de fournir tout l’historique PoM nécessaire à l’IBD.

---

# Phase 6 — Découverte des capacités des peers

Statut global : ⬜ Planifiée

⬜ Étendre les informations de capacités des peers
⬜ Annoncer la disponibilité des headers
⬜ Annoncer la disponibilité des bodies
⬜ Annoncer la disponibilité UTXO / state
⬜ Annoncer la disponibilité du Service State
⬜ Annoncer la disponibilité des preuves PoM
⬜ Annoncer la profondeur de rétention
⬜ Annoncer le plus ancien DAA PoM disponible
⬜ Annoncer la version du protocole IBD supportée
⬜ Annoncer la taille maximale de chunk supportée

Objectif :

Ne pas perdre du temps pendant l’IBD à découvrir trop tard qu’un peer n’est pas capable de fournir les données demandées.

---

# Phase 7 — Scheduler IBD multi-peers

Statut global : ⬜ Planifiée

⬜ Autoriser plusieurs peers à participer à une même session IBD
⬜ Séparer les ressources IBD par type de données
⬜ Assigner dynamiquement les chunks
⬜ Mesurer la bande passante des peers
⬜ Mesurer la latence des peers
⬜ Mesurer la fiabilité des peers
⬜ Réassigner les chunks en timeout
⬜ Réassigner les chunks après déconnexion
⬜ Pénaliser les peers systématiquement peu fiables
⬜ Ne pas bannir globalement un peer pour de simples limitations de capacité IBD

Objectif :

Un peer lent ou incomplet ne doit plus déterminer la vitesse de tout l’IBD.

---

# Phase 8 — Chunks d’état adressés par contenu

Statut global : ⬜ Planifiée

⬜ Définir une sérialisation canonique des chunks
⬜ Hasher chaque chunk
⬜ Lier les chunks à un pruning point
⬜ Lier les chunks à un commitment global d’état
⬜ Détecter les chunks en doublon
⬜ Autoriser des chunks provenant de différents fournisseurs
⬜ Vérifier les chunks avant acceptation permanente
⬜ Mettre en cache localement les chunks vérifiés

Objectif :

L’identité du fournisseur devient secondaire. Seul le contenu cryptographique compte.

---

# Phase 9 — Distribution rapide de l’état

Statut global : ⬜ Planifiée

⬜ Le transport principal reste P2P
⬜ Autoriser plusieurs fournisseurs d’état
⬜ Autoriser des mirrors communautaires
⬜ Autoriser des mirrors opérés par des pools
⬜ Autoriser des mirrors opérés par des exchanges
⬜ Transport HTTPS optionnel
⬜ Transport CDN optionnel
⬜ Même contenu indépendamment du transport
⬜ Même vérification cryptographique indépendamment de la source

Objectif :

HTTP/HTTPS peut améliorer la disponibilité et le débit mais ne doit jamais devenir une exigence de confiance.

---

# Phase 10 — IBD compatible NAT / CGNAT

Statut global : ⬜ Planifiée

⬜ Nécessiter uniquement des connexions sortantes pour les nodes standards
⬜ Ne pas exiger de redirection de port pour synchroniser
⬜ Garder le P2P entrant optionnel
⬜ Support UPnP optionnel
⬜ Support NAT-PMP optionnel
⬜ Support PCP optionnel
⬜ Fallback P2P entre plusieurs peers sortants
⬜ Fallback HTTPS sur le port 443 lorsque le P2P est bloqué

Objectif obligatoire :

Un nouvel utilisateur derrière un CGNAT avec zéro port entrant ouvert doit pouvoir démarrer `keryxd`, découvrir des peers, télécharger l’état, tout vérifier localement et atteindre `SYNCED`.

---

# Phase 11 — Tests de récupération et adversariaux

Statut global : 🟨 Partiellement préparée, campagne réelle en attente

⬜ Déconnecter un peer pendant la synchro des headers
🧪 Déconnecter/tuer pendant la synchro UTXO
🧪 Déconnecter/tuer pendant la synchro Service State
⬜ Déconnecter un peer pendant la synchro PoM
🟨 Tuer le processus du node pendant chaque étape IBD
🧪 Redémarrer après un téléchargement partiel UTXO/Service State
🧪 Changer de fournisseur pendant une reprise UTXO/Service State
⬜ Envoyer un chunk d’état invalide
⬜ Envoyer une preuve PoM corrompue
⬜ Envoyer des chunks en doublon
⬜ Envoyer les chunks dans le mauvais ordre
⬜ Peer annonçant des données qu’il ne possède pas réellement
⬜ Peer devenant extrêmement lent
✅ Checkpoints d’un pruning point périmé rejetés
⬜ Plusieurs peers envoyant des données contradictoires
⬜ Tous les mirrors optionnels indisponibles
⬜ Synchronisation P2P uniquement toujours fonctionnelle

Les fault points UTXO et Service State sont déjà disponibles et certifiés par tests locaux. Leur validation mainnet reste à exécuter lorsque les nodes pourront tourner.

Objectif :

L’IBD doit échouer proprement et pouvoir reprendre efficacement.

---

# Phase 12 — Validation des performances

Statut global : 🟨 Baseline disponible, comparaison IBD v2 non encore exécutée

La roadmap initiale mentionnait Keryx v1.5.4 comme baseline. Le projet a ensuite figé la baseline active sur **Keryx v1.5.5**, commit `bb408d54ca3992f7f9f4e269507f7603c234d24d`, afin de rester compatible avec l’upstream actuel.

✅ Établir une baseline canonique : RUN A v1.5.5 = 95,17 min
⬜ Comparer IBD v2 à la baseline
⬜ Tester sur HDD
⬜ Tester sur SSD SATA
✅ Tester sur NVMe pour la baseline
⬜ Tester avec peu de RAM
✅ Tester avec beaucoup de RAM pour la baseline
⬜ Tester avec une connexion Internet lente
⬜ Tester avec forte latence
⬜ Tester avec pertes de paquets
🟨 Tester avec un seul peer
⬜ Tester avec plusieurs peers au sens scheduler Phase 7
⬜ Tester un node CGNAT / outbound-only

Mesurer :

- durée totale IBD
- trafic réseau
- pic RAM
- utilisation CPU
- I/O disque
- temps de récupération après restart
- quantité de données téléchargées inutilement
- utilisation des peers

---

# Phase 13 — Déploiement du protocole

Statut global : ⬜ Planifiée

⬜ Définir une version de protocole Keryx IBD
⬜ Maintenir la compatibilité avec les anciens peers
⬜ Négocier les capacités pendant le handshake
⬜ Activer IBD v2 uniquement si les deux peers le supportent
⬜ Revenir automatiquement à l’IBD legacy
⬜ Tester les réseaux mixtes
⬜ Tester un déploiement progressif
⬜ Documenter les besoins pour les opérateurs

Cible :

Nouveau node + Nouveau peer → IBD v2

Nouveau node + Ancien peer → IBD legacy

Ancien node + Nouveau peer → IBD legacy

Pas besoin de mise à jour forcée de tout le réseau pour le premier déploiement.

---

# Principes de sécurité

✅ Aucun snapshot blockchain de confiance

✅ Aucun serveur central obligatoire

✅ Aucun endpoint Keryx Labs obligatoire

✅ Aucun endpoint pool obligatoire

✅ Aucun DNS seed obligatoire comme source de confiance

✅ Aucun port entrant obligatoire pour l’objectif final

✅ Chaque commitment d’état vérifié localement

✅ Chaque bloc vérifié localement

✅ Chaque preuve PoM vérifiée localement

✅ La source du transport ne détermine jamais la validité

---

# Ordre d’implémentation obligatoire

1. Phase 0 — Instrumentation
2. Phase 1 — Service State resumable
3. Phase 2 — UTXO resumable
4. Phase 3 — Suivi indépendant des états IBD
5. Phase 4 — Batching base de données
6. Phase 5 — IBD compatible PoM
7. Phase 6 — Capacités des peers
8. Phase 7 — Scheduler multi-peers
9. Phase 8 — Chunks adressés par contenu
10. Phase 9 — Distribution rapide de l’état
11. Phase 10 — Support NAT / CGNAT
12. Phase 11 — Tests adversariaux
13. Phase 12 — Validation des performances
14. Phase 13 — Déploiement progressif du protocole

**Règle de travail : ne plus renuméroter, fusionner ou avancer une phase hors de cet ordre sans décision explicite.**
