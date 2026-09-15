import 'package:graphql_schema3/graphql_schema3.dart';

/// What a subscription server answers for one operation: the data, and any
/// errors.
///
/// Shared by both transports, so that a server speaking one protocol can be
/// moved to the other without rewriting what it answers.
class GraphQLResult {
  /// The `data` of the response, null when the operation failed outright.
  final dynamic data;

  /// The errors to report alongside [data], empty when there were none.
  final Iterable<GraphQLExceptionError> errors;

  /// Pairs [data] with the [errors] to report.
  GraphQLResult(this.data, {this.errors = const []});
}
