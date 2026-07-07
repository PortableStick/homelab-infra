/// <reference path="../pb_data/types.d.ts" />
// Collections mangetout — toutes owner-only, avec métadonnées de sync
// (user, clientUpdatedAt, deleted). Le homelab est la source de vérité.
migrate(
  (app) => {
    const usersId = app.findCollectionByNameOrId('users').id;

    // Règles d'accès owner-only : chaque utilisateur ne voit/écrit que ses données.
    const owner = {
      listRule: 'user = @request.auth.id',
      viewRule: 'user = @request.auth.id',
      createRule: '@request.auth.id != null && user = @request.auth.id',
      updateRule: 'user = @request.auth.id',
      deleteRule: 'user = @request.auth.id',
    };

    // Champs de synchronisation communs à toutes les entités.
    const meta = () => [
      {
        type: 'relation',
        name: 'user',
        required: true,
        maxSelect: 1,
        collectionId: usersId,
        cascadeDelete: true,
      },
      { type: 'number', name: 'clientUpdatedAt', required: true },
      { type: 'bool', name: 'deleted' },
    ];

    // Crée une collection et renvoie son id (pour les relations en aval).
    // `parentCond` (optionnel) durcit create/update pour valider l'appartenance
    // des relations parent (empêche de rattacher un enfant au parent d'autrui).
    const create = (name, fields, parentCond) => {
      const rules = { ...owner };
      if (parentCond) {
        rules.createRule = `${owner.createRule} && ${parentCond}`;
        rules.updateRule = `${owner.updateRule} && ${parentCond}`;
      }
      const collection = new Collection({ type: 'base', name, ...rules, fields: [...meta(), ...fields] });
      app.save(collection);
      return app.findCollectionByNameOrId(name).id;
    };

    const gymsId = create('gyms', [
      { type: 'text', name: 'name', required: true },
      { type: 'text', name: 'gymType' }, // chain | home
    ]);

    create(
      'equipment',
      [
        { type: 'text', name: 'name', required: true },
        { type: 'relation', name: 'gym', maxSelect: 1, collectionId: gymsId, cascadeDelete: true },
        { type: 'text', name: 'category' },
        { type: 'json', name: 'muscleGroups' },
      ],
      "(gym = '' || gym.user = @request.auth.id)"
    );

    const foodsId = create('foods', [
      { type: 'text', name: 'name', required: true },
      { type: 'text', name: 'brand' },
      { type: 'text', name: 'barcode' },
      { type: 'text', name: 'source' }, // off | manual | ai
      { type: 'number', name: 'kcal_100g' },
      { type: 'number', name: 'protein_100g' },
      { type: 'number', name: 'carbs_100g' },
      { type: 'number', name: 'fat_100g' },
      { type: 'text', name: 'servingSize' },
      { type: 'json', name: 'offData' },
    ]);

    const mealsId = create('meals', [
      { type: 'text', name: 'name', required: true },
      { type: 'number', name: 'portions' },
    ]);

    create(
      'meal_items',
      [
        { type: 'relation', name: 'meal', required: true, maxSelect: 1, collectionId: mealsId, cascadeDelete: true },
        { type: 'relation', name: 'food', maxSelect: 1, collectionId: foodsId },
        { type: 'number', name: 'quantity_g' },
      ],
      "meal.user = @request.auth.id && (food = '' || food.user = @request.auth.id)"
    );

    create(
      'food_entries',
      [
        { type: 'text', name: 'date', required: true }, // YYYY-MM-DD
        { type: 'text', name: 'mealType' }, // breakfast | lunch | dinner | snack
        { type: 'relation', name: 'food', maxSelect: 1, collectionId: foodsId },
        { type: 'number', name: 'quantity_g' },
        { type: 'number', name: 'kcal' },
        { type: 'number', name: 'protein_g' },
        { type: 'number', name: 'carbs_g' },
        { type: 'number', name: 'fat_g' },
        { type: 'bool', name: 'estimated' },
      ],
      "(food = '' || food.user = @request.auth.id)"
    );

    create('weight_entries', [
      { type: 'text', name: 'date', required: true },
      { type: 'number', name: 'weight_kg' },
      { type: 'json', name: 'measurements' },
    ]);

    const workoutsId = create(
      'workouts',
      [
        { type: 'text', name: 'date', required: true },
        { type: 'relation', name: 'gym', maxSelect: 1, collectionId: gymsId },
        { type: 'text', name: 'notes' },
      ],
      "(gym = '' || gym.user = @request.auth.id)"
    );

    const equipmentId = app.findCollectionByNameOrId('equipment').id;
    const exercisesId = create(
      'exercises',
      [
        { type: 'relation', name: 'workout', required: true, maxSelect: 1, collectionId: workoutsId, cascadeDelete: true },
        { type: 'relation', name: 'equipment', maxSelect: 1, collectionId: equipmentId },
        { type: 'text', name: 'name' },
        { type: 'number', name: 'position' },
      ],
      "workout.user = @request.auth.id && (equipment = '' || equipment.user = @request.auth.id)"
    );

    create(
      'sets',
      [
        { type: 'relation', name: 'exercise', required: true, maxSelect: 1, collectionId: exercisesId, cascadeDelete: true },
        { type: 'number', name: 'reps' },
        { type: 'number', name: 'weight_kg' },
        { type: 'number', name: 'position' },
      ],
      'exercise.user = @request.auth.id'
    );

    create('goals', [
      { type: 'number', name: 'kcal' },
      { type: 'number', name: 'protein_g' },
      { type: 'number', name: 'carbs_g' },
      { type: 'number', name: 'fat_g' },
      { type: 'number', name: 'weight_target_kg' },
    ]);

    create('meal_plans', [
      { type: 'text', name: 'weekStart', required: true }, // YYYY-MM-DD (lundi)
      { type: 'json', name: 'plan' },
    ]);

    // Durcit la collection auth `users` : chacun ne voit/modifie que son profil
    // (empêche l'énumération des comptes). createRule laissé tel quel (auto-provisioning
    // OAuth / création admin — à décider par l'humain selon AUTH_MODE).
    const users = app.findCollectionByNameOrId('users');
    users.listRule = 'id = @request.auth.id';
    users.viewRule = 'id = @request.auth.id';
    users.updateRule = 'id = @request.auth.id';
    users.deleteRule = 'id = @request.auth.id';
    app.save(users);
  },
  (app) => {
    // Down : suppression dans l'ordre inverse des dépendances.
    const names = [
      'meal_plans',
      'goals',
      'sets',
      'exercises',
      'workouts',
      'weight_entries',
      'food_entries',
      'meal_items',
      'meals',
      'foods',
      'equipment',
      'gyms',
    ];
    for (const name of names) {
      try {
        app.delete(app.findCollectionByNameOrId(name));
      } catch (_) {
        // déjà absente
      }
    }
  }
);
