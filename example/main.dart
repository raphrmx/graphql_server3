import 'package:graphql_schema3/graphql_schema3.dart';
import 'package:graphql_server3/graphql_server3.dart';

/// Executes a query against a schema built by hand.
Future<void> main() async {
  final user = objectType(
    'User',
    fields: <GraphQLObjectField<dynamic, dynamic>>[
      field('name', graphQLString, resolve: (obj, _) => obj['name']),
      field('age', graphQLInt, resolve: (obj, _) => obj['age']),
    ],
  );

  final schema = graphQLSchema(
    queryType: objectType(
      'Query',
      fields: <GraphQLObjectField<dynamic, dynamic>>[
        field(
          'user',
          user,
          resolve: (_, _) => <String, dynamic>{'name': 'anna', 'age': 30},
        ),
        field(
          'echo',
          graphQLString,
          inputs: <GraphQLFieldInput<String, String>>[
            GraphQLFieldInput<String, String>('text', graphQLString),
          ],
          resolve: (_, args) => args['text'] as String?,
        ),
      ],
    ),
  );

  final server = GraphQL(schema);

  print(await server.parseAndExecute('{ user { name age } }'));
  // {user: {name: anna, age: 30}}

  print(
    await server.parseAndExecute(
      r'query Echo($t: String) { echo(text: $t) }',
      variableValues: <String, dynamic>{'t': 'hello'},
    ),
  );
  // {echo: hello}

  // Introspection is on by default.
  print(await server.parseAndExecute('{ __schema { queryType { name } } }'));
  // {__schema: {queryType: {name: Query}}}
}
