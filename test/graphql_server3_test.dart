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
}) async {
  final GraphQL server = GraphQL(buildSchema());
  final Object? result = await server.parseAndExecute(
    query,
    variableValues: variables,
  );
  return (result as Map).cast<String, dynamic>();
}

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
    // which is a four-line query that takes the whole isolate down.
    test('a self-spreading fragment terminates', () async {
      final Map<String, dynamic> data = await run(
        '{ user { ...f } } fragment f on User { name ...f }',
      );

      expect(data['user'], <String, dynamic>{'name': 'anna'});
    });

    test('a cycle through two fragments terminates', () async {
      final Map<String, dynamic> data = await run(
        '{ user { ...a } } '
        'fragment a on User { name ...b } '
        'fragment b on User { age ...a }',
      );

      expect(data['user'], <String, dynamic>{'name': 'anna', 'age': 30});
    });
  });

  group('known gap: no document validation', () {
    test('an unknown field yields an empty object', () async {
      expect((await run('{ user { nickname } }'))['user'], isEmpty);
    });

    test('an unknown fragment spread yields an empty object', () async {
      expect((await run('{ user { ...nope } }'))['user'], isEmpty);
    });

    test('an undeclared variable resolves to null', () async {
      final Map<String, dynamic> data = await run(
        r'query Q { echo(text: $missing) }',
      );

      expect(data['echo'], isNull);
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
