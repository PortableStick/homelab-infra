/// <reference path="../pb_data/types.d.ts" />

// Schéma initial de Trame.
//
// La règle qui compte est la même partout : `owner = @request.auth.id`.
// Sans elle, « quelques utilisateurs » signifie « tout le monde voit tout »
// (SPEC §10.3, critère d'acceptation n°11). Elle est posée sur les cinq
// opérations de chaque collection, et la règle de création vérifie en plus
// que l'appelant ne peut pas écrire un bloc au nom de quelqu'un d'autre.

migrate((app) => {
  const users = app.findCollectionByNameOrId('users');

  const ownerField = {
    name: 'owner',
    type: 'relation',
    required: true,
    collectionId: users.id,
    cascadeDelete: true,   // supprimer un compte purge ses données (SPEC §10.2)
    maxSelect: 1,
  };

  // Les cinq règles, identiques partout. La création exige que `owner` soit
  // l'appelant : on ne peut pas écrire chez autrui, même en forgeant la requête.
  const ownerOnly = {
    listRule:   'owner = @request.auth.id',
    viewRule:   'owner = @request.auth.id',
    createRule: '@request.auth.id != "" && owner = @request.auth.id',
    updateRule: 'owner = @request.auth.id',
    deleteRule: 'owner = @request.auth.id',
  };

  // ── Catégories ─────────────────────────────────────────────────────────
  // Teinte et chroma seulement : les clartés sont imposées par le client,
  // c'est ce qui garantit le contraste (SPEC §6). Aucune couleur stockée en
  // hexadécimal, sinon un jour quelqu'un en écrira une illisible.
  app.save(new Collection({
    name: 'categories',
    type: 'base',
    ...ownerOnly,
    fields: [
      ownerField,
      { name: 'label',    type: 'text',   required: true, max: 60 },
      { name: 'hue',      type: 'number', required: true, min: 0, max: 359, onlyInt: true },
      { name: 'chroma',   type: 'number', required: true, min: 0, max: 0.4 },
      { name: 'position', type: 'number', required: false, onlyInt: true },
      { name: 'created',  type: 'autodate', onCreate: true },
      { name: 'updated',  type: 'autodate', onCreate: true, onUpdate: true },
    ],
    indexes: ['CREATE INDEX idx_categories_owner ON categories (owner)'],
  }));

  // La relation de `blocks` est validée à l'enregistrement : l'identifiant de
  // la collection cible doit exister avant. D'où l'ordre, et cette lecture.
  const categoriesId = app.findCollectionByNameOrId('categories').id;

  // ── Blocs ──────────────────────────────────────────────────────────────
  // Un seul objet : pas de distinction tâche/événement imposée (SPEC §5).
  // Seul `title` est obligatoire côté produit ; `start` et `duration` sont
  // posés par le geste, donc requis techniquement.
  app.save(new Collection({
    name: 'blocks',
    type: 'base',
    ...ownerOnly,
    fields: [
      ownerField,
      { name: 'title',    type: 'text',   required: true, max: 200 },
      { name: 'start',    type: 'date',   required: true },
      // Durée minimale 5 min (SPEC §4). Plafond à 24 h : au-delà, c'est une
      // erreur de saisie, pas un bloc.
      { name: 'duration', type: 'number', required: true, min: 5, max: 1440, onlyInt: true },
      { name: 'category', type: 'relation', required: false, collectionId: categoriesId, maxSelect: 1, cascadeDelete: false },
      { name: 'note',     type: 'editor',  required: false },
      // Pas de valeur « en retard » : elle n'existe pas dans ce produit (P4).
      { name: 'state',    type: 'select', required: true, maxSelect: 1,
        values: ['planned', 'done', 'skipped', 'moved'] },
      { name: 'done_at',  type: 'date',   required: false },
      // [{label, done}] — édité d'un bloc, pas une collection à part :
      // une sous-tâche n'a pas de vie propre.
      { name: 'subtasks', type: 'json',   required: false, maxSize: 20000 },
      { name: 'alert_end',      type: 'bool',   required: false },
      { name: 'buffer_before',  type: 'number', required: false, min: 0, max: 60, onlyInt: true },
      { name: 'buffer_after',   type: 'number', required: false, min: 0, max: 60, onlyInt: true },
      { name: 'location',   type: 'text', required: false, max: 200 },
      { name: 'recurrence', type: 'json', required: false, maxSize: 2000 },
      { name: 'created', type: 'autodate', onCreate: true },
      { name: 'updated', type: 'autodate', onCreate: true, onUpdate: true },
    ],
    // L'index (owner, start) est celui de la requête de base : « les blocs de
    // cet utilisateur entre deux dates ». Il porte la cible des 100 ms (§9).
    indexes: [
      'CREATE INDEX idx_blocks_owner_start ON blocks (owner, start)',
      'CREATE INDEX idx_blocks_alert ON blocks (alert_end, start)',
    ],
  }));

  // ── Inbox ──────────────────────────────────────────────────────────────
  // Capture sans date (SPEC §7.5). Rien ne se perd en attendant d'être planifié.
  app.save(new Collection({
    name: 'inbox_items',
    type: 'base',
    ...ownerOnly,
    fields: [
      ownerField,
      { name: 'title',   type: 'text', required: true, max: 200 },
      { name: 'created', type: 'autodate', onCreate: true },
    ],
    indexes: ['CREATE INDEX idx_inbox_owner ON inbox_items (owner, created)'],
  }));

  // ── Abonnements Web Push ───────────────────────────────────────────────
  // Nécessaires à l'alerte « fin − 5 min » : aucun minuteur d'arrière-plan
  // n'est fiable dans un navigateur, la notification part du serveur (§10.4).
  app.save(new Collection({
    name: 'push_subscriptions',
    type: 'base',
    ...ownerOnly,
    fields: [
      ownerField,
      { name: 'endpoint',   type: 'text', required: true, max: 500 },
      { name: 'p256dh',     type: 'text', required: true, max: 200 },
      { name: 'auth',       type: 'text', required: true, max: 200 },
      { name: 'user_agent', type: 'text', required: false, max: 300 },
      { name: 'created',    type: 'autodate', onCreate: true },
    ],
    indexes: ['CREATE UNIQUE INDEX idx_push_endpoint ON push_subscriptions (endpoint)'],
  }));

  // ── Vue d'administration ───────────────────────────────────────────────
  // « L'administrateur gère les comptes, il ne lit pas les agendas »
  // (SPEC §10.3). Ce n'est pas une promesse d'interface : cette vue ne
  // CONTIENT aucun titre, aucune note, aucun horaire. L'écran d'admin ne peut
  // pas afficher ce qu'il n'a pas. Règles nulles = réservé aux superusers.
  app.save(new Collection({
    name: 'user_stats',
    type: 'view',
    listRule: null,
    viewRule: null,
    viewQuery: `
        SELECT
          u.id                        AS id,
          u.email                     AS email,
          u.created                   AS created,
          COUNT(b.id)                 AS block_count,
          MAX(b.updated)              AS last_activity
        FROM users u
        LEFT JOIN blocks b ON b.owner = u.id
        GROUP BY u.id
    `,
  }));

  // ── Préférences utilisateur ────────────────────────────────────────────
  // Police, taille, densité, thème, plage active, week-end affiché.
  // Un seul champ JSON : ces réglages n'ont de sens que pris ensemble et ne
  // sont jamais requêtés individuellement (SPEC §6).
  const usersCol = app.findCollectionByNameOrId('users');
  usersCol.fields.add(new TextField({ name: 'display_name', required: false, max: 80 }));
  usersCol.fields.add(new JSONField({ name: 'settings', required: false, maxSize: 5000 }));
  app.save(usersCol);

}, (app) => {
  // Retour arrière, dans l'ordre inverse des dépendances.
  for (const name of ['user_stats', 'push_subscriptions', 'inbox_items', 'blocks', 'categories']) {
    try { app.delete(app.findCollectionByNameOrId(name)); } catch (_) { /* déjà absente */ }
  }
  const users = app.findCollectionByNameOrId('users');
  for (const f of ['display_name', 'settings']) {
    const field = users.fields.getByName(f);
    if (field) users.fields.removeByName(f);
  }
  app.save(users);
});
