import 'package:graphql_schema3/graphql_schema3.dart';
import 'package:graphql_server3/graphql_server3.dart';
import 'package:test/test.dart';

/// Counts how many times the `user` resolver ran, so that a merged selection
/// set can be shown to resolve its field once rather than once per selection.
int userResolverCalls = 0;

/// A tiny schema: a query returning a user, an echo taking arguments, and an
/// enum, which is enough to exercise resolution, coercion and introspection.
GraphQLSchema buildSchema() {
  final GraphQLEnumType<String> status = enumTypeFromStrings('Status', <String>[
    'active',
    'inProgress',
  ]);

  final GraphQLObjectType user = objectType(
    'User',
    fields: <GraphQLObjectField<dynamic, dynamic>>[
      field('name', graphQLString, resolve: (dynamic obj, _) => obj['name']),
      field('age', graphQLInt, resolve: (dynamic obj, _) => obj['age']),
      field('status', status, resolve: (dynamic obj, _) => obj['status']),
    ],
  );

  final GraphQLObjectType tag = objectType(
    'Tag',
    fields: <GraphQLObjectField<dynamic, dynamic>>[
      field('label', graphQLString, resolve: (dynamic o, _) => o['label']),
    ],
  );

  return graphQLSchema(
    mutationType: objectType(
      'Mutation',
      fields: <GraphQLObjectField<dynamic, dynamic>>[
        field(
          'rename',
          graphQLString,
          inputs: <GraphQLFieldInput<String, String>>[
            GraphQLFieldInput<String, String>('to', graphQLString),
          ],
          resolve: (_, Map<String, dynamic> args) => args['to'] as String?,
        ),
      ],
    ),
    queryType: objectType(
      'Query',
      fields: <GraphQLObjectField<dynamic, dynamic>>[
        field(
          'user',
          user,
          resolve: (_, _) {
            userResolverCalls++;
            return <String, dynamic>{
              'name': 'anna',
              'age': 30,
              'status': 'active',
            };
          },
        ),
        field(
          'echo',
          graphQLString,
          inputs: <GraphQLFieldInput<String, String>>[
            GraphQLFieldInput<String, String>('text', graphQLString),
          ],
          resolve: (_, Map<String, dynamic> args) => args['text'] as String?,
        ),
        field(
          'tags',
          listOf(tag),
          resolve: (_, _) => <Map<String, dynamic>>[
            <String, dynamic>{'label': 'a'},
            <String, dynamic>{'label': 'b'},
          ],
        ),
        field('nothing', graphQLString, resolve: (_, _) => null),
        field(
          'boom',
          graphQLString,
          resolve: (_, _) => throw StateError('resolver exploded'),
        ),
        field(
          'sum',
          graphQLFloat,
          inputs: <GraphQLFieldInput<double, double>>[
            GraphQLFieldInput<double, double>(
              'value',
              graphQLFloat.nonNullable(),
            ),
          ],
          resolve: (_, Map<String, dynamic> args) =>
              (args['value'] as num).toDouble(),
        ),
      ],
    ),
  );
}

Future<Map<String, dynamic>> run(
  String query, {
  Map<String, dynamic> variables = const <String, dynamic>{},
  bool validate = true,
}) async {
  final GraphQL server = GraphQL(buildSchema(), validate: validate);
  final Object? result = await server.parseAndExecute(
    query,
    variableValues: variables,
  );
  return (result as Map).cast<String, dynamic>();
}

/// Matches a [GraphQLException] whose messages, joined, satisfy [messages].
///
/// Joined rather than taken one by one, because validation reports every fault
/// it found and the order between them is not part of the contract.
Matcher failsWith(Object messages) => throwsA(
  isA<GraphQLException>().having(
    (GraphQLException e) =>
        e.errors.map((GraphQLExceptionError x) => x.message).join(' | '),
    'messages',
    messages,
  ),
);

void main() {
  group('execution', () {
    test('resolves a nested selection', () async {
      final Map<String, dynamic> data = await run('{ user { name age } }');

      expect(data['user'], <String, dynamic>{'name': 'anna', 'age': 30});
    });

    test('honours a field alias', () async {
      final Map<String, dynamic> data = await run('{ who: user { name } }');

      expect(data.containsKey('who'), isTrue);
      expect(data['who'], <String, dynamic>{'name': 'anna'});
    });

    test('passes a literal argument to the resolver', () async {
      final Map<String, dynamic> data = await run('{ echo(text: "hi") }');

      expect(data['echo'], 'hi');
    });

    test('passes a variable to the resolver', () async {
      final Map<String, dynamic> data = await run(
        r'query Echo($t: String) { echo(text: $t) }',
        variables: <String, dynamic>{'t': 'from variable'},
      );

      expect(data['echo'], 'from variable');
    });

    test('expands a fragment', () async {
      final Map<String, dynamic> data = await run(
        '{ user { ...names } } fragment names on User { name }',
      );

      expect(data['user'], <String, dynamic>{'name': 'anna'});
    });

    test('reports a syntax error as a GraphQL error', () async {
      expect(() => run('{ user {'), throwsA(isA<GraphQLException>()));
    });
  });

  group('argument coercion', () {
    test('accepts an integer literal for a non-null Float argument', () async {
      // The parser hands over an int; the spec coerces it to Float.
      final Map<String, dynamic> data = await run('{ sum(value: 4) }');

      expect(data['sum'], 4.0);
    });

    test('accepts an integer variable for a non-null Float argument', () async {
      final Map<String, dynamic> data = await run(
        r'query S($v: Float!) { sum(value: $v) }',
        variables: <String, dynamic>{'v': 4},
      );

      expect(data['sum'], 4.0);
    });

    test('rejects a missing non-null argument', () async {
      expect(() => run('{ sum }'), throwsA(isA<GraphQLException>()));
    });
  });

  group('enums', () {
    test('resolves a declared value', () async {
      final Map<String, dynamic> data = await run('{ user { status } }');

      expect(data['user'], <String, dynamic>{'status': 'active'});
    });
  });

  group('introspection', () {
    test('answers the schema query type name', () async {
      final Map<String, dynamic> data = await run(
        '{ __schema { queryType { name } } }',
      );

      expect((data['__schema'] as Map)['queryType'], <String, dynamic>{
        'name': 'Query',
      });
    });

    test('lists the fields of a type', () async {
      final Map<String, dynamic> data = await run(
        '{ __type(name: "User") { name fields { name } } }',
      );

      final Map<dynamic, dynamic> type = data['__type'] as Map;
      expect(type['name'], 'User');
      expect(
        (type['fields'] as List<dynamic>).map(
          (dynamic f) => (f as Map)['name'],
        ),
        containsAll(<String>['name', 'age', 'status']),
      );
    });

    test('reports enum values as they were declared', () async {
      final Map<String, dynamic> data = await run(
        '{ __type(name: "Status") { enumValues { name } } }',
      );

      final List<dynamic> values =
          (data['__type'] as Map)['enumValues'] as List<dynamic>;

      expect(values.map((dynamic v) => (v as Map)['name']), <String>[
        'active',
        'inProgress',
      ]);
    });

    test('spells directive locations in screaming snake case', () async {
      // The only place the package rewrites a name, and the one that used to
      // lean on `recase`.
      final Map<String, dynamic> data = await run(
        '{ __type(name: "__DirectiveLocation") { enumValues { name } } }',
      );

      final List<dynamic> values =
          (data['__type'] as Map)['enumValues'] as List<dynamic>;
      final Iterable<dynamic> names = values.map(
        (dynamic v) => (v as Map)['name'],
      );

      expect(names, contains('QUERY'));
      expect(names, contains('FRAGMENT_DEFINITION'));
      expect(
        names.every((dynamic n) => n == (n as String).toUpperCase()),
        isTrue,
      );
    });

    test('answers the typename of a selection', () async {
      final Map<String, dynamic> data = await run('{ user { __typename } }');

      expect(data['user'], <String, dynamic>{'__typename': 'User'});
    });
  });

  group('directives', () {
    test('skip removes a field when its condition holds', () async {
      final Map<String, dynamic> data = await run(
        '{ user { name @skip(if: true) age } }',
      );

      expect(data['user'], <String, dynamic>{'age': 30});
    });

    test('skip keeps a field when its condition is false', () async {
      final Map<String, dynamic> data = await run(
        '{ user { name @skip(if: false) } }',
      );

      expect(data['user'], <String, dynamic>{'name': 'anna'});
    });

    test('include keeps a field only when its condition holds', () async {
      expect(
        (await run('{ user { name @include(if: true) } }'))['user'],
        <String, dynamic>{'name': 'anna'},
      );
      expect(
        (await run('{ user { name @include(if: false) age } }'))['user'],
        <String, dynamic>{'age': 30},
      );
    });

    test('honours the shorthand @skip: true form', () async {
      final Map<String, dynamic> data = await run(
        '{ user { name @skip: true age } }',
      );

      expect(data['user'], <String, dynamic>{'age': 30});
    });

    test(
      'ignores a directive whose argument is not the one asked for',
      () async {
        final Map<String, dynamic> data = await run(
          '{ user { name @skip(unless: true) } }',
        );

        expect(data['user'], <String, dynamic>{'name': 'anna'});
      },
    );

    test('skip reads its condition from a variable', () async {
      final Map<String, dynamic> data = await run(
        r'query Q($s: Boolean!) { user { name @skip(if: $s) age } }',
        variables: <String, dynamic>{'s': true},
      );

      expect(data['user'], <String, dynamic>{'age': 30});
    });
  });

  group('variables', () {
    test('falls back to the declared default', () async {
      final Map<String, dynamic> data = await run(
        r'query Q($t: String = "fallback") { echo(text: $t) }',
      );

      expect(data['echo'], 'fallback');
    });

    test('an explicit value wins over the default', () async {
      final Map<String, dynamic> data = await run(
        r'query Q($t: String = "fallback") { echo(text: $t) }',
        variables: <String, dynamic>{'t': 'given'},
      );

      expect(data['echo'], 'given');
    });
  });

  group('selection shapes', () {
    test('resolves an alias on a nested field', () async {
      final Map<String, dynamic> data = await run('{ user { label: name } }');

      expect(data['user'], <String, dynamic>{'label': 'anna'});
    });

    test('asks for the same field twice under two aliases', () async {
      final Map<String, dynamic> data = await run(
        '{ a: user { name } b: user { age } }',
      );

      expect(data['a'], <String, dynamic>{'name': 'anna'});
      expect(data['b'], <String, dynamic>{'age': 30});
    });

    test('answers __typename at the root', () async {
      final Map<String, dynamic> data = await run('{ __typename }');

      expect(data['__typename'], 'Query');
    });

    test('merges two selection sets on the same field', () async {
      final Map<String, dynamic> data = await run(
        '{ user { name } user { age } }',
      );

      expect(data['user'], <String, dynamic>{'name': 'anna', 'age': 30});
    });

    test('resolves a merged field once, not once per selection', () async {
      userResolverCalls = 0;
      await run('{ user { name } user { age } }');

      expect(userResolverCalls, 1);
    });
  });

  group('lists and nulls', () {
    test('resolves a list of objects', () async {
      final Map<String, dynamic> data = await run('{ tags { label } }');

      expect(data['tags'], <Map<String, dynamic>>[
        <String, dynamic>{'label': 'a'},
        <String, dynamic>{'label': 'b'},
      ]);
    });

    test('carries a null through a nullable field', () async {
      final Map<String, dynamic> data = await run('{ nothing }');

      expect(data.containsKey('nothing'), isTrue);
      expect(data['nothing'], isNull);
    });
  });

  group('mutations', () {
    test('executes a mutation', () async {
      final Map<String, dynamic> data = await run(
        'mutation M { rename(to: "bob") }',
      );

      expect(data['rename'], 'bob');
    });
  });

  group('resolver failures', () {
    test('a throwing resolver surfaces rather than being swallowed', () async {
      expect(() => run('{ boom }'), throwsA(isA<Object>()));
    });
  });

  // The document is executed optimistically, never validated against the schema
  // first. These three cases all turn a client typo into silently wrong data
  // rather than an error, and they are one missing feature seen from three
  // angles. Recorded so that changing the behaviour is a deliberate act.
  group('operation selection', () {
    test('names the ambiguity when several operations are unnamed', () async {
      expect(
        () => run('query A { user { name } } query B { user { age } }'),
        throwsA(
          isA<GraphQLException>().having(
            (GraphQLException e) => e.errors.first.message,
            'message',
            contains('2 operations'),
          ),
        ),
      );
    });

    test('reports a document with no operation at all', () async {
      expect(
        () => run('fragment f on User { name }'),
        throwsA(
          isA<GraphQLException>().having(
            (GraphQLException e) => e.errors.first.message,
            'message',
            contains('does not define any operations'),
          ),
        ),
      );
    });

    test('runs the operation asked for by name', () async {
      final GraphQL server = GraphQL(buildSchema());
      final Object? result = await server.parseAndExecute(
        'query A { user { name } } query B { user { age } }',
        operationName: 'B',
      );

      expect((result as Map)['user'], <String, dynamic>{'age': 30});
    });
  });

  group('fragment cycles', () {
    // A fragment that spreads itself used to recurse until the stack gave out,
    // which is a four-line query that takes the whole isolate down. Validation
    // now refuses the document, and the guard in collectFields stays for the
    // executor's own sake.
    test('a self-spreading fragment is refused', () async {
      await expectLater(
        run('{ user { ...f } } fragment f on User { name ...f }'),
        failsWith(contains('Cannot spread fragment "f" within itself.')),
      );
    });

    test('a cycle through two fragments is refused', () async {
      await expectLater(
        run(
          '{ user { ...a } } '
          'fragment a on User { name ...b } '
          'fragment b on User { age ...a }',
        ),
        failsWith(
          contains('Cannot spread fragment "a" within itself via "b".'),
        ),
      );
    });

    test('one cycle is reported once, not once per member', () async {
      try {
        await run(
          '{ user { ...a } } '
          'fragment a on User { name ...b } '
          'fragment b on User { age ...a }',
        );
        fail('the document should have been refused');
      } on GraphQLException catch (e) {
        expect(e.errors, hasLength(1));
      }
    });

    test('a self-spreading fragment still terminates unvalidated', () async {
      final Map<String, dynamic> data = await run(
        '{ user { ...f } } fragment f on User { name ...f }',
        validate: false,
      );

      expect(data['user'], <String, dynamic>{'name': 'anna'});
    });

    test('a two-fragment cycle still terminates unvalidated', () async {
      final Map<String, dynamic> data = await run(
        '{ user { ...a } } '
        'fragment a on User { name ...b } '
        'fragment b on User { age ...a }',
        validate: false,
      );

      expect(data['user'], <String, dynamic>{'name': 'anna', 'age': 30});
    });
  });

  group('document validation', () {
    test('refuses a field the type does not declare', () async {
      await expectLater(
        run('{ user { nickname } }'),
        failsWith(contains('Cannot query field "nickname" on type "User".')),
      );
    });

    test('refuses a spread naming no fragment', () async {
      await expectLater(
        run('{ user { ...nope } }'),
        failsWith(contains('Unknown fragment "nope".')),
      );
    });

    test('refuses a variable the operation does not declare', () async {
      await expectLater(
        run(r'query Q { echo(text: $missing) }'),
        failsWith(
          contains(r'Variable "$missing" is not defined by operation "Q".'),
        ),
      );
    });

    test('follows a spread to the variables the fragment uses', () async {
      await expectLater(
        run(r'query Q { ...f } fragment f on Query { echo(text: $t) }'),
        failsWith(contains(r'Variable "$t" is not defined by operation "Q".')),
      );
    });

    test('accepts a variable declared for a fragment that uses it', () async {
      final Map<String, dynamic> data = await run(
        r'query Q($t: String) { ...f } fragment f on Query { echo(text: $t) }',
        variables: <String, dynamic>{'t': 'hi'},
      );

      expect(data['echo'], 'hi');
    });

    test('refuses a selection on a scalar field', () async {
      await expectLater(
        run('{ user { name { first } } }'),
        failsWith(contains('must not have a selection since type "String"')),
      );
    });

    test('refuses an object field carrying no selection', () async {
      await expectLater(
        run('{ user }'),
        failsWith(
          contains('Field "user" of type "User" must have a selection'),
        ),
      );
    });

    test('refuses a fragment on a type the schema does not declare', () async {
      await expectLater(
        run('{ user { ...f } } fragment f on Ghost { name }'),
        failsWith(contains('Unknown type "Ghost".')),
      );
    });

    test('refuses two operations sharing a name', () async {
      await expectLater(
        run('query A { user { name } } query A { user { age } }'),
        failsWith(contains('There can be only one operation named "A".')),
      );
    });

    test('refuses an anonymous operation alongside another', () async {
      await expectLater(
        run('{ user { name } } query B { user { age } }'),
        failsWith(contains('anonymous operation must be the only operation')),
      );
    });

    test('refuses two fragments sharing a name', () async {
      await expectLater(
        run(
          '{ user { ...f } } '
          'fragment f on User { name } '
          'fragment f on User { age }',
        ),
        failsWith(contains('There can be only one fragment named "f".')),
      );
    });

    test('reports every fault at once', () async {
      await expectLater(
        run('{ user { nickname } tags { colour } }'),
        failsWith(allOf(contains('"nickname"'), contains('"colour"'))),
      );
    });

    test('runs no resolver when the document is refused', () async {
      userResolverCalls = 0;

      await expectLater(
        run('{ user { name nickname } }'),
        throwsA(isA<GraphQLException>()),
      );
      expect(userResolverCalls, 0);
    });

    test('answers __typename without calling it a field', () async {
      expect((await run('{ user { __typename } }'))['user'], <String, dynamic>{
        '__typename': 'User',
      });
    });

    test('is off unless the constructor asks for it', () async {
      // The default is what a server taking this version gets without touching
      // its code, so it is pinned rather than assumed.
      final GraphQL server = GraphQL(buildSchema());
      final Object? result = await server.parseAndExecute(
        '{ user { nickname } }',
      );

      expect((result as Map)['user'], isEmpty);
    });

    test('leaves the 3.2 behaviour in place when turned off', () async {
      expect(
        (await run('{ user { nickname } }', validate: false))['user'],
        isEmpty,
      );
      expect(
        (await run('{ user { ...nope } }', validate: false))['user'],
        isEmpty,
      );
      expect(
        (await run(
          r'query Q { echo(text: $missing) }',
          validate: false,
        ))['echo'],
        isNull,
      );
    });
  });

  group('argument names', () {
    test('refuses an argument the field does not declare', () async {
      await expectLater(
        run('{ echo(txt: "a") }'),
        failsWith(contains('Unknown argument "txt" on field "Query.echo".')),
      );
    });

    test('refuses an argument on a field that takes none', () async {
      await expectLater(
        run('{ user(id: 1) { name } }'),
        failsWith(contains('Unknown argument "id" on field "Query.user".')),
      );
    });

    test('accepts the argument the field declares', () async {
      expect((await run('{ echo(text: "a") }'))['echo'], 'a');
    });
  });

  group('selection merging', () {
    // Two selections under one response key resolve once, so the second used
    // to disappear from the answer without a word.
    test('refuses two different fields under one alias', () async {
      await expectLater(
        run('{ user { a: name a: age } }'),
        failsWith(
          contains(
            'Fields "a" conflict because "name" and "age" are '
            'different fields.',
          ),
        ),
      );
    });

    test('refuses one field asked twice with different arguments', () async {
      await expectLater(
        run('{ echo(text: "x") echo(text: "y") }'),
        failsWith(
          contains(
            'Fields "echo" conflict because they are given different '
            'arguments.',
          ),
        ),
      );
    });

    test('accepts one field asked twice with the same arguments', () async {
      expect((await run('{ echo(text: "x") echo(text: "x") }'))['echo'], 'x');
    });

    test('compares variables by name, not by value', () async {
      await expectLater(
        run(
          r'query Q($a: String, $b: String) { echo(text: $a) echo(text: $b) }',
          variables: <String, dynamic>{'a': 'x', 'b': 'x'},
        ),
        failsWith(contains('given different arguments')),
      );

      expect(
        (await run(
          r'query Q($a: String) { echo(text: $a) echo(text: $a) }',
          variables: <String, dynamic>{'a': 'x'},
        ))['echo'],
        'x',
      );
    });

    test('accepts two fields under two aliases', () async {
      expect(
        (await run('{ user { a: name b: age } }'))['user'],
        <String, dynamic>{'a': 'anna', 'b': 30},
      );
    });

    test('accepts __typename asked twice', () async {
      expect(
        (await run('{ user { __typename __typename } }'))['user'],
        <String, dynamic>{'__typename': 'User'},
      );
    });
  });

  group('fragment placement', () {
    test('refuses a fragment on a type the parent can never be', () async {
      await expectLater(
        run('{ user { ...f } } fragment f on Tag { label }'),
        failsWith(
          contains(
            'Fragment "f" cannot be spread here, as objects of type '
            '"User" can never be of type "Tag".',
          ),
        ),
      );
    });

    test('refuses an inline fragment the parent can never be', () async {
      await expectLater(
        run('{ user { ... on Tag { label } } }'),
        failsWith(contains('can never be of type "Tag"')),
      );
    });

    test('accepts a fragment on the parent type itself', () async {
      final Map<String, dynamic> data = await run(
        '{ user { ...f } } fragment f on User { name }',
      );

      expect(data['user'], <String, dynamic>{'name': 'anna'});
    });
  });

  group('foldToStringDynamic', () {
    test('widens the keys of a dynamic map', () {
      expect(
        foldToStringDynamic(<dynamic, dynamic>{1: 'a', 'b': 2}),
        <String, dynamic>{'1': 'a', 'b': 2},
      );
    });

    test('answers an empty map for null', () {
      expect(foldToStringDynamic(null), isEmpty);
    });
  });
}
