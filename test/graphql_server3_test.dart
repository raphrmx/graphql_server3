import 'package:graphql_schema3/graphql_schema3.dart';
import 'package:graphql_server3/graphql_server3.dart';
import 'package:test/test.dart';

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

  return graphQLSchema(
    queryType: objectType(
      'Query',
      fields: <GraphQLObjectField<dynamic, dynamic>>[
        field(
          'user',
          user,
          resolve: (_, _) => <String, dynamic>{
            'name': 'anna',
            'age': 30,
            'status': 'active',
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

    test('answers an empty object for an unknown field', () async {
      // Known gap: selection sets are not validated against the schema, so a
      // client typo yields empty data rather than an error.
      final Map<String, dynamic> data = await run('{ user { nickname } }');

      expect(data['user'], isEmpty);
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
