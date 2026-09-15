import 'package:collection/collection.dart' show IterableExtension;
import 'package:graphql_parser3/graphql_parser3.dart';
import 'package:graphql_schema3/graphql_schema3.dart';

/// Checks [document] against [schema] and answers every error found.
///
/// An empty list means the document may be executed. [knownTypes] is the type
/// registry a fragment's type condition is resolved against, which is what
/// `GraphQL.customTypes` holds.
///
/// The rules applied, named as the GraphQL specification names them:
///
/// - 5.2.1.1 and 5.5.1.1, an operation or fragment name is defined once, and
///   an anonymous operation stands alone.
/// - 5.3.1, a field is declared by the type it is selected on.
/// - 5.3.2, two selections sharing a response key name the same field with the
///   same arguments. Only selections written side by side are compared, not
///   ones brought together through a fragment.
/// - 5.3.3, a field naming an object type carries a selection of subfields,
///   and one naming a scalar or an enum carries none.
/// - 5.4.1, a field's arguments are declared by that field.
/// - 5.5.1.2, a fragment's type condition names a composite type the schema
///   declares.
/// - 5.5.2.1, a fragment spread names a fragment the document defines.
/// - 5.5.2.2, no fragment spreads itself, directly or through a chain.
/// - 5.5.2.3, a fragment is spread somewhere it can apply.
/// - 5.8.3, every variable a document uses is declared by its operation.
///
/// Two rules are left out on purpose. 5.7.1, directives are defined, because
/// this package carries application directives such as `@jsonpath` and
/// refusing whatever a schema does not declare would break consumers over a
/// directive they own. 5.5.1.4, fragments must be used, because a document
/// carrying a fragment it does not spread harms nobody.
///
/// Argument values are checked during execution rather than here: coercion
/// already refuses a missing or mistyped one.
List<GraphQLExceptionError> validateDocument(
  DocumentContext document,
  GraphQLSchema schema,
  List<GraphQLType> knownTypes,
) => _Validator(document, schema, knownTypes).run();

/// Walks a document once, collecting what the schema refuses.
class _Validator {
  _Validator(this.document, this.schema, this.knownTypes) {
    for (final fragment
        in document.definitions.whereType<FragmentDefinitionContext>()) {
      _fragments.putIfAbsent(fragment.name, () => fragment);
    }
  }

  final DocumentContext document;
  final GraphQLSchema schema;
  final List<GraphQLType> knownTypes;

  final Map<String?, FragmentDefinitionContext> _fragments = {};
  final List<GraphQLExceptionError> _errors = [];

  List<GraphQLExceptionError> run() {
    final operations = document.definitions
        .whereType<OperationDefinitionContext>()
        .toList();
    final fragments = document.definitions
        .whereType<FragmentDefinitionContext>()
        .toList();

    _checkNamesAreUnique(operations, fragments);
    _checkFragmentCycles(fragments);

    // A fragment is checked against its own type condition rather than at each
    // of its spreads, so a fragment spread twice reports its faults once.
    for (final fragment in fragments) {
      final on = _conditionType(
        fragment.typeCondition,
        'Fragment "${fragment.name}"',
      );
      if (on != null) _walkSelectionSet(fragment.selectionSet, on);
    }

    for (final operation in operations) {
      final root = _rootTypeOf(operation);
      if (root != null) _walkSelectionSet(operation.selectionSet, root);
      _checkVariableUses(operation);
    }

    return _errors;
  }

  // --------------------------------------------------------------- 5.2 / 5.5

  void _checkNamesAreUnique(
    List<OperationDefinitionContext> operations,
    List<FragmentDefinitionContext> fragments,
  ) {
    final seenOperations = <String>{};

    for (final operation in operations) {
      final name = operation.name;

      if (name == null) {
        if (operations.length > 1) {
          _report(
            'This anonymous operation must be the only operation in the '
            'document.',
            operation,
          );
        }
        continue;
      }

      if (!seenOperations.add(name)) {
        _report('There can be only one operation named "$name".', operation);
      }
    }

    final seenFragments = <String?>{};

    for (final fragment in fragments) {
      if (!seenFragments.add(fragment.name)) {
        _report(
          'There can be only one fragment named "${fragment.name}".',
          fragment,
        );
      }
    }
  }

  void _checkFragmentCycles(List<FragmentDefinitionContext> fragments) {
    // One cycle is one error however many of its members the walk starts from,
    // so a cycle is keyed by its members rather than by the message.
    final reported = <String>{};

    for (final fragment in fragments) {
      _detectCycle(fragment, fragment.name, const [], <String?>{}, reported);
    }
  }

  void _detectCycle(
    FragmentDefinitionContext fragment,
    String? root,
    List<String?> path,
    Set<String?> visited,
    Set<String> reported,
  ) {
    if (!visited.add(fragment.name)) return;

    for (final spread in _spreadsIn(fragment.selectionSet)) {
      if (spread.name == root) {
        final members = <String?>[root, ...path]
          ..sort((a, b) => (a ?? '').compareTo(b ?? ''));

        if (reported.add(members.join(','))) {
          final via = path.isEmpty
              ? ''
              : ' via ${path.map((name) => '"$name"').join(', ')}';
          _report('Cannot spread fragment "$root" within itself$via.', spread);
        }
        continue;
      }

      final target = _fragments[spread.name];
      // A spread naming nothing is the unknown-fragment rule's business.
      if (target == null) continue;

      _detectCycle(target, root, [...path, spread.name], visited, reported);
    }
  }

  Iterable<FragmentSpreadContext> _spreadsIn(
    SelectionSetContext selectionSet,
  ) sync* {
    for (final selection in selectionSet.selections) {
      final spread = selection.fragmentSpread;
      if (spread != null) yield spread;

      final inner =
          selection.field?.selectionSet ??
          selection.inlineFragment?.selectionSet;
      if (inner != null) yield* _spreadsIn(inner);
    }
  }

  // --------------------------------------------------------------------- 5.3

  void _walkSelectionSet(SelectionSetContext selectionSet, GraphQLType parent) {
    // The first field met under each response key, kept so that the next one
    // sharing that key can be compared against it.
    final byResponseKey = <String?, FieldContext>{};

    for (final selection in selectionSet.selections) {
      final field = selection.field;
      final spread = selection.fragmentSpread;
      final inline = selection.inlineFragment;

      if (field != null) {
        _checkMerge(byResponseKey, field);
        _walkField(field, parent);
      } else if (spread != null) {
        final fragment = _fragments[spread.name];

        if (fragment == null) {
          _report('Unknown fragment "${spread.name}".', spread);
          continue;
        }

        final on = _findType(fragment.typeCondition.typeName.name);
        if (on != null && !_canSpread(parent, on)) {
          _report(
            'Fragment "${spread.name}" cannot be spread here, as objects of '
            'type "${_nameOf(parent)}" can never be of type '
            '"${_nameOf(on)}".',
            spread,
          );
        }
      } else if (inline != null) {
        final on = _conditionType(inline.typeCondition, 'Inline fragment');
        if (on == null) continue;

        if (!_canSpread(parent, on)) {
          _report(
            'This inline fragment cannot be spread here, as objects of type '
            '"${_nameOf(parent)}" can never be of type "${_nameOf(on)}".',
            inline.typeCondition,
          );
          continue;
        }

        _walkSelectionSet(inline.selectionSet, on);
      }
    }
  }

  /// Compares [field] against the one already met under its response key.
  ///
  /// Two selections landing on the same key are resolved once, so a document
  /// that puts different fields there loses one of them without a word. The
  /// comparison covers selections written side by side; ones a fragment brings
  /// together are not checked.
  void _checkMerge(
    Map<String?, FieldContext> byResponseKey,
    FieldContext field,
  ) {
    final responseKey = field.fieldName.alias?.alias ?? field.fieldName.name;
    final first = byResponseKey[responseKey];

    if (first == null) {
      byResponseKey[responseKey] = field;
      return;
    }

    final firstName = first.fieldName.alias?.name ?? first.fieldName.name;
    final name = field.fieldName.alias?.name ?? field.fieldName.name;

    if (firstName != name) {
      _report(
        'Fields "$responseKey" conflict because "$firstName" and "$name" are '
        'different fields. Use different aliases to fetch both.',
        field,
      );
      return;
    }

    if (_argumentsKey(first) != _argumentsKey(field)) {
      _report(
        'Fields "$responseKey" conflict because they are given different '
        'arguments. Use different aliases to fetch both.',
        field,
      );
    }
  }

  /// The arguments of [field] in a form two selections can be compared on.
  String _argumentsKey(FieldContext field) {
    final parts = [
      for (final argument in field.arguments)
        '${argument.name}:${_valueKey(argument.value)}',
    ]..sort();

    return parts.join(',');
  }

  String _valueKey(InputValueContext value) {
    if (value is VariableContext) return '\$${value.name}';

    if (value is ListValueContext) {
      return '[${value.values.map(_valueKey).join(',')}]';
    }

    if (value is ObjectValueContext) {
      final fields = [
        for (final field in value.fields)
          '${field.nameToken.text}:${_valueKey(field.value)}',
      ]..sort();
      return '{${fields.join(',')}}';
    }

    if (value is NullValueContext) return 'null';

    return '${value.computeValue(const <String, dynamic>{})}';
  }

  /// Whether a fragment conditioned on [condition] can apply under [parent].
  ///
  /// Answers the question the executor asks at run time, one type at a time,
  /// so that a document is refused only when no possible type of [parent] could
  /// ever match. A [parent] whose possible types are unknown answers true
  /// rather than guessing.
  bool _canSpread(GraphQLType parent, GraphQLType condition) {
    final candidates = _concreteTypesOf(parent);
    if (candidates.isEmpty) return true;

    return candidates.any((type) => _appliesTo(type, condition));
  }

  bool _appliesTo(GraphQLObjectType object, GraphQLType condition) {
    if (condition is GraphQLUnionType) {
      return condition.possibleTypes.any(object.isImplementationOf);
    }

    if (condition is GraphQLObjectType) {
      if (condition.isInterface) return object.isImplementationOf(condition);

      // The rule the executor applies to a concrete condition: it holds when
      // the object carries every field the condition declares. Matching it
      // here keeps validation from refusing what execution would have run.
      return condition.fields.every(
        (declared) => object.fields.any((f) => f.name == declared.name),
      );
    }

    return false;
  }

  List<GraphQLObjectType> _concreteTypesOf(GraphQLType type) {
    if (type is GraphQLUnionType) return type.possibleTypes;

    if (type is GraphQLObjectType) {
      return type.isInterface ? type.possibleTypes : [type];
    }

    return const [];
  }

  String _nameOf(GraphQLType type) => type.name ?? type.toString();

  void _walkField(FieldContext field, GraphQLType parent) {
    final name = field.fieldName.alias?.name ?? field.fieldName.name;
    final selectionSet = field.selectionSet;

    // Answered by the executor rather than by the type, on every composite.
    if (name == '__typename') {
      if (selectionSet != null) {
        _report(
          'Field "__typename" must not have a selection since type "String" '
          'has no subfields.',
          field,
        );
      }
      return;
    }

    if (parent is GraphQLUnionType) {
      _report(
        'Cannot query field "$name" on union type "${parent.name}". Name it '
        'inside an inline fragment on one of its member types.',
        field,
      );
      return;
    }

    if (parent is! GraphQLObjectType) return;

    final declared = parent.fields.firstWhereOrNull((f) => f.name == name);

    if (declared == null) {
      _report('Cannot query field "$name" on type "${parent.name}".', field);
      return;
    }

    for (final argument in field.arguments) {
      if (!declared.inputs.any((input) => input.name == argument.name)) {
        _report(
          'Unknown argument "${argument.name}" on field '
          '"${parent.name}.$name".',
          argument,
        );
      }
    }

    final type = _namedType(declared.type);
    final composite = type is GraphQLObjectType || type is GraphQLUnionType;

    if (composite) {
      if (selectionSet == null || selectionSet.selections.isEmpty) {
        _report(
          'Field "$name" of type "${type.name}" must have a selection of '
          'subfields.',
          field,
        );
        return;
      }
      _walkSelectionSet(selectionSet, type);
    } else if (selectionSet != null) {
      _report(
        'Field "$name" must not have a selection since type "${type.name}" '
        'has no subfields.',
        field,
      );
    }
  }

  // --------------------------------------------------------------------- 5.8

  void _checkVariableUses(OperationDefinitionContext operation) {
    final declared = <String>{
      for (final definition
          in operation.variableDefinitions?.variableDefinitions ??
              const <VariableDefinitionContext>[])
        definition.variable.name,
    };

    final used = <String, Node>{};
    _collectVariables(operation.selectionSet, used, <String?>{});
    for (final directive in operation.directives) {
      _collectFromDirective(directive, used);
    }

    final where = operation.name == null
        ? ''
        : ' by operation "${operation.name}"';

    for (final use in used.entries) {
      if (!declared.contains(use.key)) {
        _report('Variable "\$${use.key}" is not defined$where.', use.value);
      }
    }
  }

  void _collectVariables(
    SelectionSetContext selectionSet,
    Map<String, Node> used,
    Set<String?> seenFragments,
  ) {
    for (final selection in selectionSet.selections) {
      final field = selection.field;
      final spread = selection.fragmentSpread;
      final inline = selection.inlineFragment;

      if (field != null) {
        for (final argument in field.arguments) {
          _collectFromValue(argument.value, used);
        }
        for (final directive in field.directives) {
          _collectFromDirective(directive, used);
        }
        final inner = field.selectionSet;
        if (inner != null) _collectVariables(inner, used, seenFragments);
      } else if (spread != null) {
        for (final directive in spread.directives) {
          _collectFromDirective(directive, used);
        }
        // A fragment carries its variables into whichever operation spreads
        // it, so the walk crosses the spread. The set stops a cycle.
        if (!seenFragments.add(spread.name)) continue;
        final fragment = _fragments[spread.name];
        if (fragment == null) continue;
        for (final directive in fragment.directives) {
          _collectFromDirective(directive, used);
        }
        _collectVariables(fragment.selectionSet, used, seenFragments);
      } else if (inline != null) {
        for (final directive in inline.directives) {
          _collectFromDirective(directive, used);
        }
        _collectVariables(inline.selectionSet, used, seenFragments);
      }
    }
  }

  void _collectFromDirective(
    DirectiveContext directive,
    Map<String, Node> used,
  ) {
    final argument = directive.argument;
    if (argument != null) _collectFromValue(argument.value, used);

    final value = directive.value;
    if (value != null) _collectFromValue(value, used);
  }

  void _collectFromValue(InputValueContext value, Map<String, Node> used) {
    if (value is VariableContext) {
      used.putIfAbsent(value.name, () => value);
    } else if (value is ListValueContext) {
      for (final item in value.values) {
        _collectFromValue(item, used);
      }
    } else if (value is ObjectValueContext) {
      for (final field in value.fields) {
        _collectFromValue(field.value, used);
      }
    }
  }

  // ------------------------------------------------------------------ shared

  GraphQLObjectType? _rootTypeOf(OperationDefinitionContext operation) {
    if (operation.isMutation) {
      final type = schema.mutationType;
      if (type == null) {
        _report('This schema does not define a mutation type.', operation);
      }
      return type;
    }

    if (operation.isSubscription) {
      final type = schema.subscriptionType;
      if (type == null) {
        _report('This schema does not define a subscription type.', operation);
      }
      return type;
    }

    final type = schema.queryType;
    if (type == null) {
      _report('This schema does not define a query type.', operation);
    }
    return type;
  }

  /// The composite type [condition] names, or null once the fault is reported.
  ///
  /// [subject] opens the message, so that a non-composite condition reads as
  /// the fragment or the inline fragment it was written on.
  GraphQLType? _conditionType(TypeConditionContext condition, String subject) {
    final name = condition.typeName.name;
    final type = _findType(name);

    if (type == null) {
      _report('Unknown type "$name".', condition);
      return null;
    }

    if (type is! GraphQLObjectType && type is! GraphQLUnionType) {
      _report(
        '$subject cannot condition on non composite type "$name".',
        condition,
      );
      return null;
    }

    return type;
  }

  /// Looks [name] up the way the executor does, `polymorphicName` included.
  GraphQLType? _findType(String? name) {
    if (name == null) return null;

    return knownTypes.firstWhereOrNull((type) => type.name == name) ??
        knownTypes.firstWhereOrNull(
          (type) => type is GraphQLObjectType && type.polymorphicName == name,
        );
  }

  /// Strips the list and non-null wrappers off [type].
  GraphQLType _namedType(GraphQLType type) {
    var current = type;

    while (true) {
      if (current is GraphQLNonNullableType) {
        current = current.ofType;
      } else if (current is GraphQLListType) {
        current = current.ofType;
      } else {
        return current;
      }
    }
  }

  void _report(String message, Node? node) {
    final span = node?.span;

    _errors.add(
      GraphQLExceptionError(
        message,
        locations: span == null
            ? const []
            : [GraphExceptionErrorLocation.fromSourceLocation(span.start)],
      ),
    );
  }
}
