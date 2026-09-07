/// Executes GraphQL documents against a `graphql_schema3` schema.
///
/// [GraphQL] is the whole of it: give it a schema, call
/// [GraphQL.parseAndExecute] with a query, and get back the `data` map, or a
/// `Stream` of them for a subscription. Introspection is wired up by default.
///
/// Serving this over HTTP or a WebSocket is deliberately left out, because it
/// belongs to whichever framework you are using. For subscriptions over
/// Apollo's `subscriptions-transport-ws`, see `subscriptions_transport_ws.dart`.
library;

import 'dart:async';
import 'package:collection/collection.dart' show IterableExtension;
import 'package:graphql_parser3/graphql_parser3.dart';
import 'package:graphql_schema3/graphql_schema3.dart';
import 'introspection.dart';

/// Transforms any [Map] into `Map<String, dynamic>`.
Map<String, dynamic> foldToStringDynamic(Map? map) {
  if (map == null) {
    return {};
  }
  return map.keys.fold<Map<String, dynamic>>(
    <String, dynamic>{},
    (out, k) => out..[k.toString()] = map[k],
  );
}

/// A variable whose value is not sent by the client, but read back out of the
/// response while it is being built.
///
/// Declared with the `@jsonpath` directive on a variable definition. The path
/// is dotted and rooted at `$`, so `$.user.id` waits until the `user` field has
/// resolved and then takes its `id`. Until then the variable holds this object
/// rather than a value; [complete] replaces it.
class JsonPathArgument {
  /// Splits [path] into its segments.
  ///
  /// Throws if it does not start with `$` and name at least one field.
  JsonPathArgument(
    this.path,
    this.definition,
    this.defaultValue,
    this.variableValues,
  ) : _spl = path.split('.') {
    if (_spl.isEmpty || _spl.length < 2 || _spl.first != r'$') {
      throw 'Bad json path $path';
    }

    _spl.removeAt(0);
  }

  /// The path as written, `$` included.
  final String path;

  /// The coerced variable map this argument writes itself into once completed.
  final Map<String, dynamic> variableValues;
  final List<String> _spl;

  /// The value to record when the path resolves to null.
  final dynamic defaultValue;

  /// The path segments, without the leading `$`.
  Iterable<String> get splitted => _spl;

  /// The variable definition the `@jsonpath` directive was attached to.
  final VariableDefinitionContext definition;

  /// Records [value] as this variable's value, or [defaultValue] if it is null.
  void complete(dynamic value) {
    variableValues[definition.variable.name] = value ?? defaultValue;
  }
}

/// A Dart implementation of a GraphQL server.
class GraphQL {
  /// Any custom types to include in introspection information.
  final List<GraphQLType> customTypes = [];

  /// An optional callback that can be used to resolve fields from objects that are not [Map]s,
  /// when the related field has no resolver.
  final FutureOr<T> Function<T>(T, String?, Map<String, dynamic>)?
  defaultFieldResolver;

  GraphQLSchema _schema;

  /// Binds a [schema] to an executor.
  ///
  /// Pass `introspect: false` to leave `__schema` and `__type` out of the
  /// schema; every type is still registered, so a fragment on a named type
  /// keeps resolving. [defaultFieldResolver] is consulted for a field that has
  /// no resolver of its own on an object that is not a [Map]. [customTypes]
  /// adds types that no field mentions, which introspection would otherwise
  /// never reach.
  GraphQL(
    GraphQLSchema schema, {
    bool introspect = true,
    this.defaultFieldResolver,
    List<GraphQLType> customTypes = const <GraphQLType>[],
  }) : _schema = schema {
    if (customTypes.isNotEmpty == true) {
      this.customTypes.addAll(customTypes);
    }

    var allTypes = fetchAllTypes(schema, [...this.customTypes]);

    if (introspect) {
      _schema = reflectSchema(_schema, allTypes);
    }

    for (var type in allTypes.toSet()) {
      if (!this.customTypes.contains(type)) {
        if (type != null) {
          this.customTypes.add(type);
        }
      }
    }

    if (_schema.queryType != null) {
      this.customTypes.add(_schema.queryType!);
    }
    if (_schema.mutationType != null) {
      this.customTypes.add(_schema.mutationType!);
    }
    if (_schema.subscriptionType != null) {
      this.customTypes.add(_schema.subscriptionType!);
    }
  }

  /// Resolves a type reference parsed from a query against the schema.
  ///
  /// Scalar names are answered directly; anything else is looked up among the
  /// registered types. With [usePolymorphicName] and a [parent], a name is
  /// matched against `polymorphicName` among that parent's possible types
  /// first. Throws [ArgumentError] if the name is not in the schema.
  GraphQLType convertType(
    TypeContext ctx, {
    bool usePolymorphicName = false,
    GraphQLObjectType? parent,
  }) {
    var listType = ctx.listType;
    var typeName = ctx.typeName;
    if (listType != null) {
      var convert = convertType(listType.innerType);
      return GraphQLListType(convert);
    } else if (typeName != null) {
      final name = typeName.name;

      switch (name) {
        case 'Int':
          return graphQLInt;
        case 'Float':
          return graphQLFloat;
        case 'String':
          return graphQLString;
        case 'Boolean':
          return graphQLBoolean;
        case 'ID':
          return graphQLId;
        case 'Date':
        case 'DateTime':
          return graphQLDate;
        default:
          usePolymorphicName = usePolymorphicName && parent != null;

          if (usePolymorphicName) {
            final ret = customTypes.firstWhereOrNull((t) {
              return t is GraphQLObjectType &&
                  t.polymorphicName == name &&
                  parent.possibleTypes.contains(t);
            });

            if (ret != null) {
              return ret;
            }
          }

          return customTypes.firstWhere(
            (t) {
              return t.name == name;
            },
            orElse: () => throw ArgumentError('Unknown GraphQL type: "$name"'),
          );
      }
    } else {
      throw ArgumentError('Invalid GraphQL type: "${ctx.span.text}"');
    }
  }

  /// Parses [text] and executes it. The usual entry point.
  ///
  /// Answers the `data` map for a query or a mutation, and a `Stream` of them
  /// for a subscription. [operationName] picks one operation out of a document
  /// that defines several. Throws [GraphQLException] on a syntax error, on a
  /// variable or argument that fails coercion, and on a null produced for a
  /// non-nullable field.
  ///
  /// The document is not validated against the schema first: an unknown field
  /// or fragment yields an empty object rather than an error.
  Future parseAndExecute(
    String text, {
    String? operationName,
    sourceUrl,
    Map<String, dynamic> variableValues = const {},
    initialValue,
    Map<String, dynamic> globalVariables = const {},
  }) {
    var tokens = scan(text, sourceUrl: sourceUrl);
    var parser = Parser(tokens);
    var document = parser.parseDocument();

    if (parser.errors.isNotEmpty) {
      throw GraphQLException(
        parser.errors
            .map(
              (e) => GraphQLExceptionError(
                e.message,
                locations: [
                  GraphExceptionErrorLocation.fromSourceLocation(e.span!.start),
                ],
              ),
            )
            .toList(),
      );
    }

    return executeRequest(
      _schema,
      document,
      operationName: operationName,
      initialValue: initialValue,
      variableValues: variableValues,
      globalVariables: globalVariables,
    );
  }

  /// Executes an already-parsed [document] against [schema].
  ///
  /// Coerces the variables, then dispatches to the query, mutation or
  /// subscription path according to the operation.
  Future executeRequest(
    GraphQLSchema schema,
    DocumentContext document, {
    String? operationName,
    Map<String, dynamic> variableValues = const <String, dynamic>{},
    initialValue,
    Map<String, dynamic> globalVariables = const <String, dynamic>{},
  }) async {
    var operation = getOperation(document, operationName);
    var coercedVariableValues = coerceVariableValues(
      schema,
      operation,
      variableValues,
    );
    if (operation.isQuery) {
      return await executeQuery(
        document,
        operation,
        schema,
        coercedVariableValues,
        initialValue,
        globalVariables,
      );
    } else if (operation.isSubscription) {
      return await subscribe(
        document,
        operation,
        schema,
        coercedVariableValues,
        globalVariables,
        initialValue,
      );
    } else {
      return executeMutation(
        document,
        operation,
        schema,
        coercedVariableValues,
        initialValue,
        globalVariables,
      );
    }
  }

  /// Picks the operation to execute out of [document].
  ///
  /// Throws [GraphQLException] when [operationName] is null and the document
  /// holds anything other than exactly one operation, and when a name is given
  /// that the document does not define.
  OperationDefinitionContext getOperation(
    DocumentContext document,
    String? operationName,
  ) {
    var ops = document.definitions.whereType<OperationDefinitionContext>();
    if (operationName == null) {
      if (ops.isEmpty) {
        throw GraphQLException.fromMessage(
          'This document does not define any operations.',
        );
      }
      if (ops.length > 1) {
        throw GraphQLException.fromMessage(
          'This document defines ${ops.length} operations, so one must be '
          'named in the request.',
        );
      }
      return ops.first;
    } else {
      return ops.firstWhere(
        (d) => d.name == operationName,
        orElse: (() => throw GraphQLException.fromMessage(
          'Missing required operation "$operationName".',
        )),
      );
    }
  }

  /// Coerces the incoming [variableValues] against the operation's declared
  /// variable definitions.
  ///
  /// Applies each declared default, validates and deserializes what was
  /// supplied, and leaves a [JsonPathArgument] in place of a variable carrying
  /// the `@jsonpath` directive. Throws [GraphQLException] for a missing
  /// non-nullable variable or a value of the wrong type.
  Map<String, dynamic> coerceVariableValues(
    GraphQLSchema schema,
    OperationDefinitionContext operation,
    Map<String, dynamic> variableValues,
  ) {
    var coercedValues = <String, dynamic>{};
    var variableDefinitions =
        operation.variableDefinitions?.variableDefinitions ?? [];

    for (var variableDefinition in variableDefinitions) {
      var variableName = variableDefinition.variable.name;
      var variableType = variableDefinition.type;
      var defaultValue = variableDefinition.defaultValue;

      //if (variableName == null) {
      //  continue;
      //}
      var value = variableValues[variableName];
      dynamic toSet;

      final jp = getDirectiveValue(
        'jsonpath',
        'path',
        variableDefinition,
        variableValues,
      );

      if (value == null) {
        if (defaultValue != null) {
          toSet = defaultValue.value.computeValue(variableValues);
        } else if (!variableType.isNullable && jp == null) {
          throw GraphQLException.fromSourceSpan(
            'Missing required variable "$variableName".',
            variableDefinition.span,
          );
        }
      } else {
        var type = convertType(variableType);
        var validation = type.validate(variableName, value);

        if (!validation.successful) {
          throw GraphQLException(
            validation.errors
                .map(
                  (e) => GraphQLExceptionError(
                    e,
                    locations: [
                      GraphExceptionErrorLocation.fromSourceLocation(
                        variableDefinition.span.start,
                      ),
                    ],
                  ),
                )
                .toList(),
          );
        } else {
          toSet = type.deserialize(value);
        }
      }

      if (jp != null) {
        toSet = JsonPathArgument(jp, variableDefinition, toSet, coercedValues);
      }

      coercedValues[variableName] = toSet;
    }

    return coercedValues;
  }

  /// Collects the [JsonPathArgument]s in [map] as paths still to be filled.
  ///
  /// Each entry is the remaining path segments followed by the argument itself,
  /// so that execution can match them against response keys as it descends.
  List<List> makeLazy(Map<String, dynamic> map) {
    final lazy = <List>[];

    for (final val in map.values) {
      if (val is JsonPathArgument) {
        lazy.add([...val.splitted, val]);
      } else if (val is Map<String, dynamic>) {
        lazy.addAll(makeLazy(val));
      }
    }

    return lazy;
  }

  /// Executes a query operation and answers its `data` map.
  Future<Map<String, dynamic>> executeQuery(
    DocumentContext document,
    OperationDefinitionContext query,
    GraphQLSchema schema,
    Map<String, dynamic> variableValues,
    initialValue,
    Map<String, dynamic> globalVariables,
  ) async {
    var queryType = schema.queryType;
    var selectionSet = query.selectionSet;

    return await executeSelectionSet(
      document,
      selectionSet,
      queryType,
      initialValue,
      variableValues,
      globalVariables,
      lazy: makeLazy(variableValues),
    );
  }

  /// Executes a mutation operation and answers its `data` map.
  ///
  /// Throws [GraphQLException] if the schema defines no mutation type.
  Future<Map<String?, dynamic>> executeMutation(
    DocumentContext document,
    OperationDefinitionContext mutation,
    GraphQLSchema schema,
    Map<String, dynamic> variableValues,
    initialValue,
    Map<String, dynamic> globalVariables,
  ) async {
    var mutationType = schema.mutationType;

    if (mutationType == null) {
      throw GraphQLException.fromMessage(
        'The schema does not define a mutation type.',
      );
    }

    var selectionSet = mutation.selectionSet;
    return await executeSelectionSet(
      document,
      selectionSet,
      mutationType,
      initialValue,
      variableValues,
      globalVariables,
      lazy: makeLazy(variableValues),
    );
  }

  /// Executes a subscription operation.
  ///
  /// Answers a stream that emits one response map per source event.
  Future<Stream<Map<String, dynamic>>> subscribe(
    DocumentContext document,
    OperationDefinitionContext subscription,
    GraphQLSchema schema,
    Map<String, dynamic> variableValues,
    Map<String, dynamic> globalVariables,
    initialValue,
  ) async {
    var sourceStream = await createSourceEventStream(
      document,
      subscription,
      schema,
      variableValues,
      initialValue,
    );
    return mapSourceToResponseEvent(
      sourceStream,
      subscription,
      schema,
      document,
      initialValue,
      variableValues,
      globalVariables,
    );
  }

  /// Resolves the single root field of a subscription into its event stream.
  ///
  /// Throws [GraphQLException] if the schema defines no subscription type, or
  /// if the selection set does not name exactly one field.
  Future<Stream> createSourceEventStream(
    DocumentContext document,
    OperationDefinitionContext subscription,
    GraphQLSchema schema,
    Map<String?, dynamic> variableValues,
    initialValue,
  ) {
    var selectionSet = subscription.selectionSet;
    var subscriptionType = schema.subscriptionType;
    if (subscriptionType == null) {
      throw GraphQLException.fromSourceSpan(
        'The schema does not define a subscription type.',
        subscription.span!,
      );
    }
    var groupedFieldSet = collectFields(
      document,
      subscriptionType,
      selectionSet,
      variableValues,
    );
    if (groupedFieldSet.length != 1) {
      throw GraphQLException.fromSourceSpan(
        'The grouped field set from this query must have exactly one entry.',
        selectionSet.span!,
      );
    }
    var fields = groupedFieldSet.entries.first.value;
    var fieldName =
        fields.first.field!.fieldName.alias?.name ??
        fields.first.field!.fieldName.name;
    var field = fields.first;
    var argumentValues = coerceArgumentValues(
      subscriptionType,
      field,
      variableValues,
    );
    return resolveFieldEventStream(
      subscriptionType,
      initialValue,
      fieldName,
      argumentValues,
    );
  }

  /// Maps each event of [sourceStream] to the response it produces.
  Stream<Map<String, dynamic>> mapSourceToResponseEvent(
    Stream sourceStream,
    OperationDefinitionContext subscription,
    GraphQLSchema schema,
    DocumentContext document,
    initialValue,
    Map<String, dynamic> variableValues,
    Map<String, dynamic> globalVariables,
  ) async* {
    await for (var event in sourceStream) {
      yield await executeSubscriptionEvent(
        document,
        subscription,
        schema,
        event,
        variableValues,
        globalVariables,
      );
    }
  }

  /// Executes the subscription's selection set against one source event.
  ///
  /// A [GraphQLException] is caught and reported under the `errors` key rather
  /// than ending the stream.
  Future<Map<String, dynamic>> executeSubscriptionEvent(
    DocumentContext document,
    OperationDefinitionContext subscription,
    GraphQLSchema schema,
    initialValue,
    Map<String, dynamic> variableValues,
    Map<String, dynamic> globalVariables,
  ) async {
    var selectionSet = subscription.selectionSet;
    var subscriptionType = schema.subscriptionType;
    if (subscriptionType == null) {
      throw GraphQLException.fromSourceSpan(
        'The schema does not define a subscription type.',
        subscription.span!,
      );
    }
    try {
      var data = await executeSelectionSet(
        document,
        selectionSet,
        subscriptionType,
        initialValue,
        variableValues,
        globalVariables,
        lazy: makeLazy(variableValues),
      );
      return {'data': data};
    } on GraphQLException catch (e) {
      return {
        'data': null,
        'errors': [e.errors.map((e) => e.toJson()).toList()],
      };
    }
  }

  /// Calls the subscription field's resolver and normalises what it answers.
  ///
  /// A resolver that returns something other than a `Stream` is treated as a
  /// stream of one event. Throws [GraphQLException] if no such field exists.
  Future<Stream> resolveFieldEventStream(
    GraphQLObjectType subscriptionType,
    rootValue,
    String? fieldName,
    Map<String, dynamic> argumentValues,
  ) async {
    var field = subscriptionType.fields.firstWhere(
      (f) => f.name == fieldName,
      orElse: () {
        throw GraphQLException.fromMessage(
          'No subscription field named "$fieldName" is defined.',
        );
      },
    );
    var resolver = field.resolve!;
    var result = await resolver(rootValue, argumentValues);
    if (result is Stream) {
      return result;
    } else {
      return Stream.fromIterable([result]);
    }
  }

  /// Executes [selectionSet] against [objectValue] and answers the result map.
  ///
  /// Fields are grouped by response key, and each key is resolved once however
  /// many selections were merged into it. A key naming a field the type does
  /// not declare is skipped rather than reported.
  Future<Map<String, dynamic>> executeSelectionSet(
    DocumentContext document,
    SelectionSetContext selectionSet,
    GraphQLObjectType? objectType,
    objectValue,
    Map<String, dynamic> variableValues,
    Map<String, dynamic> globalVariables, {
    List<List> lazy = const [],
    GraphQLObjectType? parentType,
  }) async {
    var groupedFieldSet = collectFields(
      document,
      objectType!,
      selectionSet,
      variableValues,
      parentType: parentType,
    );
    var resultMap = <String, dynamic>{};

    for (var responseKey in groupedFieldSet.keys) {
      if (responseKey == null) {
        continue;
      }

      final nextLazy = <List>[];
      final doneLazy = <List>[];

      for (final l in lazy) {
        if (l.first == responseKey) {
          final key = l.elementAt(0);
          final arr = l..removeAt(0);

          if (l.length > 1) {
            nextLazy.add(arr);
          } else {
            doneLazy.add([key, ...arr]);
          }
        }
      }

      final fields = groupedFieldSet[responseKey] ?? [];
      if (fields.isEmpty) {
        continue;
      }

      // One response key is resolved once, however many selections were merged
      // into it: `{ user { name } user { age } }` groups two selections under
      // `user`, and they share a single call to the `user` resolver. The whole
      // group is handed to executeField, which merges their sub-selections.
      final SelectionContext field = fields.first;
      final String? fieldName =
          field.field?.fieldName.alias?.name ?? field.field?.fieldName.name;
      FutureOr<dynamic> futureResponseValue;

      if (fieldName == '__typename') {
        futureResponseValue = objectType.name;
      } else {
        final fieldType = objectType.fields
            .firstWhereOrNull((f) => f.name == fieldName)
            ?.type;

        if (fieldType == null) {
          continue;
        }

        futureResponseValue = executeField(
          document,
          fieldName,
          objectType,
          objectValue,
          fields,
          fieldType,
          Map<String, dynamic>.from(globalVariables)..addAll(variableValues),
          globalVariables,
          lazy: nextLazy.toList(),
        );
      }

      final val = resultMap[responseKey] = await futureResponseValue;

      for (final lz in doneLazy) {
        if (lz.first as String == responseKey) {
          (lz.last as JsonPathArgument).complete(val);
        }
      }
    }

    return resultMap;
  }

  /// Resolves one field: coerces its arguments, calls its resolver, then
  /// completes the value against [fieldType].
  Future executeField(
    DocumentContext document,
    String? fieldName,
    GraphQLObjectType objectType,
    dynamic objectValue,
    List<SelectionContext> fields,
    GraphQLType fieldType,
    Map<String, dynamic> variableValues,
    Map<String, dynamic> globalVariables, {
    List<List> lazy = const [],
  }) async {
    var field = fields[0];
    var argumentValues = coerceArgumentValues(
      objectType,
      field,
      variableValues,
    );
    var resolvedValue = await resolveFieldValue(
      objectType,
      objectValue,
      fieldName,
      Map<String, dynamic>.from(globalVariables)..addAll(argumentValues),
    );
    return completeValue(
      document,
      fieldName,
      fieldType,
      fields,
      resolvedValue,
      variableValues,
      globalVariables,
      lazy: lazy,
    );
  }

  /// Coerces the arguments written on [field] against the ones its definition
  /// declares.
  ///
  /// Applies defaults, accepts an explicit null for a nullable argument, and
  /// throws [GraphQLException] for a missing non-nullable argument or a value
  /// that fails the argument type's own validation.
  Map<String, dynamic> coerceArgumentValues(
    GraphQLObjectType objectType,
    SelectionContext field,
    Map<String?, dynamic> variableValues,
  ) {
    var coercedValues = <String, dynamic>{};
    var argumentValues = field.field?.arguments;
    var fieldName =
        field.field?.fieldName.alias?.name ?? field.field?.fieldName.name;
    var desiredField = objectType.fields.firstWhere(
      (f) => f.name == fieldName,
      orElse: (() => throw FormatException(
        '${objectType.name} has no field named "$fieldName".',
      )),
    );
    var argumentDefinitions = desiredField.inputs;

    for (var argumentDefinition in argumentDefinitions) {
      var argumentName = argumentDefinition.name;
      var argumentType = argumentDefinition.type;
      var defaultValue = argumentDefinition.defaultValue;

      var argumentValue = argumentValues?.firstWhereOrNull(
        (a) => a.name == argumentName,
      );

      if (argumentValue == null) {
        if (defaultValue != null || argumentDefinition.defaultsToNull) {
          coercedValues[argumentName] = defaultValue;
        } else if (argumentType is GraphQLNonNullableType) {
          throw GraphQLException.fromMessage(
            'Missing value for argument "$argumentName" of field "$fieldName".',
          );
        } else {
          continue;
        }
      } else {
        final inputValue = argumentValue.value.computeValue(
          variableValues as Map<String, dynamic>,
        );

        // An explicit `null` is a legal value for a nullable argument, and it
        // never reaches validate(): a validator answers about the *shape* of a
        // value, so it rejects null the same way it rejects a string given to
        // a list. Whether null is allowed at all is the nullable / non-nullable
        // distinction, and that is decided here. Non-nullable types keep going
        // through validate(), which already reports "Expected ... to be a
        // non-null value".
        if (inputValue == null && argumentType is! GraphQLNonNullableType) {
          coercedValues[argumentName] = null;
          continue;
        }

        try {
          final validation = argumentType.validate(argumentName, inputValue);

          if (!validation.successful) {
            var errors = <GraphQLExceptionError>[
              GraphQLExceptionError(
                'Type coercion error for value of argument "$argumentName" of field "$fieldName". ($inputValue)',
                locations: [
                  GraphExceptionErrorLocation.fromSourceLocation(
                    argumentValue.value.span!.start,
                  ),
                ],
              ),
            ];

            for (var error in validation.errors) {
              var err = argumentValue.value.span?.start;
              var locations = <GraphExceptionErrorLocation>[];
              if (err != null) {
                locations.add(
                  GraphExceptionErrorLocation.fromSourceLocation(err),
                );
              }
              errors.add(GraphQLExceptionError(error, locations: locations));
            }

            throw GraphQLException(errors);
          } else {
            final coercedValue = argumentType.deserialize(inputValue);

            coercedValues[argumentName] = coercedValue;
          }
        } on TypeError catch (e) {
          var err = argumentValue.value.span?.start;
          var locations = <GraphExceptionErrorLocation>[];
          if (err != null) {
            locations.add(GraphExceptionErrorLocation.fromSourceLocation(err));
          }

          throw GraphQLException(<GraphQLExceptionError>[
            GraphQLExceptionError(
              'Type coercion error for value of argument "$argumentName" of field "$fieldName". [$inputValue]',
              locations: locations,
            ),
            GraphQLExceptionError(e.toString(), locations: locations),
          ]);
        }
      }
    }

    return coercedValues;
  }

  /// Reads one field off [objectValue].
  ///
  /// A [Map] is read by key, which takes precedence over the field's own
  /// resolver. Otherwise the resolver runs, and failing that the
  /// `defaultFieldResolver` given to the constructor, if any.
  Future<T?> resolveFieldValue<T>(
    GraphQLObjectType objectType,
    T objectValue,
    String? fieldName,
    Map<String, dynamic> argumentValues,
  ) async {
    final field = objectType.fields.firstWhere((f) => f.name == fieldName);
    final fieldResolve = field.resolve;

    if (objectValue is Map) {
      return objectValue[fieldName] as T;
    } else if (fieldResolve == null) {
      if (defaultFieldResolver != null) {
        return await defaultFieldResolver!(
          objectValue,
          fieldName,
          argumentValues,
        );
      }
      return null;
    } else {
      return await fieldResolve(objectValue, argumentValues) as T?;
    }
  }

  /// Shapes a resolved value into its response form, following the field type.
  ///
  /// Unwraps non-null, maps over lists, serializes scalars, and recurses into
  /// the sub-selection for an object or a union. Throws [GraphQLException] for
  /// a null under a non-nullable type, for a non-iterable under a list type,
  /// and for a scalar the type cannot serialize.
  Future completeValue(
    DocumentContext document,
    String? fieldName,
    GraphQLType fieldType,
    List<SelectionContext> fields,
    dynamic result,
    Map<String, dynamic> variableValues,
    Map<String, dynamic> globalVariables, {
    List<List> lazy = const [],
  }) async {
    if (fieldType is GraphQLNonNullableType) {
      var innerType = fieldType.ofType;
      // Unwrapping `T!` into `T` is a pass-through, so the pending json path
      // arguments have to travel with it; they used to be dropped here, which
      // left a `@jsonpath` variable behind a non-nullable field uncompleted.
      var completedResult = await completeValue(
        document,
        fieldName,
        innerType,
        fields,
        result,
        variableValues,
        globalVariables,
        lazy: lazy,
      );

      if (completedResult == null) {
        throw GraphQLException.fromMessage(
          'Null value provided for non-nullable field "$fieldName".',
        );
      } else {
        return completedResult;
      }
    }

    if (result == null) {
      return null;
    }

    if (fieldType is GraphQLListType) {
      if (result is! Iterable) {
        throw GraphQLException.fromMessage(
          'Value of field "$fieldName" must be a list or iterable, got $result instead.',
        );
      }

      var innerType = fieldType.ofType;
      var futureOut = [];

      for (var resultItem in result) {
        futureOut.add(
          completeValue(
            document,
            '(item in "$fieldName")',
            innerType,
            fields,
            resultItem,
            variableValues,
            globalVariables,
          ),
        );
      }

      var out = [];
      for (var f in futureOut) {
        out.add(await f);
      }

      return out;
    }

    if (fieldType is GraphQLScalarType) {
      try {
        final ret = fieldType.serialize(result);

        return ret;
      } on TypeError {
        throw GraphQLException.fromMessage(
          'Value of field "$fieldName" must be ${fieldType.valueType}, got $result (${result.runtimeType}) instead.',
        );
      }
    }

    if (fieldType is GraphQLObjectType || fieldType is GraphQLUnionType) {
      GraphQLObjectType objectType;

      if (fieldType is GraphQLObjectType && !fieldType.isInterface) {
        objectType = fieldType;
      } else {
        objectType = resolveAbstractType(fieldName, fieldType, result);
      }

      //objectType = fieldType as GraphQLObjectType;
      var subSelectionSet = mergeSelectionSets(fields);
      return await executeSelectionSet(
        document,
        subSelectionSet,
        objectType,
        result,
        variableValues,
        globalVariables,
        lazy: lazy,
        parentType: fieldType as GraphQLObjectType,
      );
    }

    throw UnsupportedError('Unsupported type: $fieldType');
  }

  /// Decides which concrete object type [result] belongs to.
  ///
  /// Each possible type is asked to validate the value, and exactly one match
  /// wins. Throws [GraphQLException] listing every failure when none matches.
  GraphQLObjectType resolveAbstractType(
    String? fieldName,
    GraphQLType type,
    dynamic result,
  ) {
    List<GraphQLObjectType> possibleTypes;

    if (type is GraphQLObjectType) {
      if (type.isInterface) {
        possibleTypes = type.possibleTypes;
      } else {
        return type;
      }
    } else if (type is GraphQLUnionType) {
      possibleTypes = type.possibleTypes;
    } else {
      throw ArgumentError();
    }

    final errors = <GraphQLExceptionError>[];
    final types = [];

    for (var t in possibleTypes) {
      try {
        var validation = t.validate(
          fieldName!,
          foldToStringDynamic(result as Map?),
        );

        if (validation.successful) {
          types.add(t);
        } else {
          errors.addAll(validation.errors.map((m) => GraphQLExceptionError(m)));
        }
      } on GraphQLException catch (e) {
        errors.addAll(e.errors);
      }
    }

    if (types.isNotEmpty) {
      if (types.length == 1) {
        return types.first;
      } else if (type is GraphQLObjectType) {
        return type;
      }
    }

    errors.insert(
      0,
      GraphQLExceptionError('Cannot convert value $result to type $type.'),
    );

    throw GraphQLException(errors);
  }

  /// Merges the sub-selections of [fields] into one selection set.
  ///
  /// This is what lets two selections on the same response key share a single
  /// call to the field's resolver.
  SelectionSetContext mergeSelectionSets(List<SelectionContext> fields) {
    var selections = <SelectionContext>[];

    for (var field in fields) {
      if (field.field?.selectionSet != null) {
        selections.addAll(field.field!.selectionSet!.selections);
      } else if (field.inlineFragment?.selectionSet != null) {
        selections.addAll(field.inlineFragment!.selectionSet.selections);
      }
    }

    return SelectionSetContext.merged(selections);
  }

  /// Groups the selections of [selectionSet] by response key.
  ///
  /// Applies `@skip` and `@include`, and expands fragment spreads and inline
  /// fragments whose type condition holds. [visitedFragments] is shared with
  /// the recursion, so a fragment that spreads itself is expanded once instead
  /// of recursing without end.
  Map<String?, List<SelectionContext>> collectFields(
    DocumentContext document,
    GraphQLObjectType? objectType,
    SelectionSetContext selectionSet,
    Map<String?, dynamic> variableValues, {
    Set<String?>? visitedFragments,
    GraphQLObjectType? parentType,
  }) {
    var groupedFields = <String?, List<SelectionContext>>{};
    // Shared with the recursive calls below, so that a fragment that spreads
    // itself - directly or through a chain - is expanded once instead of
    // recursing until the stack gives out.
    visitedFragments ??= <String?>{};

    for (var selection in selectionSet.selections) {
      final field = selection.field;

      if (field != null) {
        if (getDirectiveValue('skip', 'if', field, variableValues) == true) {
          continue;
        }
        if (getDirectiveValue('include', 'if', field, variableValues) ==
            false) {
          continue;
        }
      }

      if (selection.field != null) {
        var responseKey =
            selection.field!.fieldName.alias?.alias ??
            selection.field!.fieldName.name;
        var groupForResponseKey = groupedFields.putIfAbsent(
          responseKey,
          () => [],
        );
        groupForResponseKey.add(selection);
      } else if (selection.fragmentSpread != null) {
        var fragmentSpreadName = selection.fragmentSpread!.name;
        if (!visitedFragments.add(fragmentSpreadName)) continue;
        var fragment = document.definitions
            .whereType<FragmentDefinitionContext>()
            .firstWhereOrNull((f) => f.name == fragmentSpreadName);

        if (fragment == null) continue;
        var fragmentType = fragment.typeCondition;
        if (!doesFragmentTypeApply(objectType, fragmentType)) continue;
        var fragmentSelectionSet = fragment.selectionSet;
        var fragmentGroupFieldSet = collectFields(
          document,
          objectType,
          fragmentSelectionSet,
          variableValues,
          visitedFragments: visitedFragments,
        );

        for (var responseKey in fragmentGroupFieldSet.keys) {
          var fragmentGroup = fragmentGroupFieldSet[responseKey]!;
          var groupForResponseKey = groupedFields.putIfAbsent(
            responseKey,
            () => [],
          );
          groupForResponseKey.addAll(fragmentGroup);
        }
      } else if (selection.inlineFragment != null) {
        var fragmentType = selection.inlineFragment!.typeCondition;
        if (!doesFragmentTypeApply(
          objectType,
          fragmentType,
          parentType: parentType,
        )) {
          continue;
        }
        var fragmentSelectionSet = selection.inlineFragment!.selectionSet;
        var fragmentGroupFieldSet = collectFields(
          document,
          objectType,
          fragmentSelectionSet,
          variableValues,
          visitedFragments: visitedFragments,
        );

        for (var responseKey in fragmentGroupFieldSet.keys) {
          var fragmentGroup = fragmentGroupFieldSet[responseKey]!;
          var groupForResponseKey = groupedFields.putIfAbsent(
            responseKey,
            () => [],
          );
          groupForResponseKey.addAll(fragmentGroup);
        }
      }
    }

    return groupedFields;
  }

  /// Reads the value a directive named [name] carries on [holder].
  ///
  /// Answers null when the directive is absent. Both syntaxes are understood:
  /// `@skip(if: true)`, whose argument must be [argumentName], and the
  /// shorthand `@skip: true`, which carries no argument name. A variable is
  /// resolved against [variableValues], and an undeclared one throws
  /// [GraphQLException].
  dynamic getDirectiveValue(
    String name,
    String argumentName,
    Directives holder,
    Map<String?, dynamic> variableValues,
  ) {
    // A directive is matched on its own name. The value it carries is read
    // from whichever of the two syntaxes the parser saw: `@skip(if: true)`,
    // whose argument must be the one asked for, or the shorthand `@skip: true`,
    // which has no argument name at all. The shorthand used to compare the
    // *value* against the directive name and so never matched anything.
    final directive = holder.directives.firstWhereOrNull((d) => d.name == name);

    if (directive == null) return null;

    final InputValueContext? vv = directive.argument == null
        ? directive.value
        : (directive.argument!.name == argumentName
              ? directive.argument!.value
              : null);

    if (vv == null) return null;

    if (vv is VariableContext) {
      var vname = vv.name;
      if (!variableValues.containsKey(vname)) {
        throw GraphQLException.fromSourceSpan(
          'Unknown variable: "$vname"',
          vv.span,
        );
      }
      return variableValues[vname];
    }
    return vv.computeValue(variableValues as Map<String, dynamic>);
  }

  /// Whether a fragment's type condition holds for [objectType].
  bool doesFragmentTypeApply(
    GraphQLObjectType? objectType,
    TypeConditionContext fragmentType, {
    GraphQLObjectType? parentType,
  }) {
    var type = convertType(
      TypeContext(fragmentType.typeName, null),
      usePolymorphicName: true,
      parent: parentType ?? objectType,
    );
    if (type is GraphQLObjectType && !type.isInterface) {
      for (var field in type.fields) {
        if (!objectType!.fields.any((f) => f.name == field.name)) return false;
      }
      return true;
    } else if (type is GraphQLObjectType && type.isInterface) {
      return objectType!.isImplementationOf(type);
    } else if (type is GraphQLUnionType) {
      return type.possibleTypes.any((t) => objectType!.isImplementationOf(t));
    }

    return false;
  }
}
