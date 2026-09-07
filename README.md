# GraphQL Server 3

[![Build](https://img.shields.io/github/actions/workflow/status/raphrmx/graphql_server3/ci.yml?branch=main&label=build)](https://github.com/raphrmx/graphql_server3/actions/workflows/ci.yml)
[![Pub Version](https://img.shields.io/pub/v/graphql_server3?color=blue)](https://pub.dev/packages/graphql_server3)
[![Maintainer](https://img.shields.io/badge/Maintainer-Raphael-purple)](https://comapps.be)
[![License](https://img.shields.io/badge/Licence-BSD--3--Clause-blue)](LICENSE)

Base package for implementing GraphQL servers. It does not require any specific framework, and
thus can be used in any Dart project.

## Where this comes from

This package is a fork of the GraphQL stack maintained as part of
[Angel3](https://github.com/dukefirehawk/angel), which itself descends from the
`graphql_*` packages Tobe O wrote for Angel. The fork is taken from the `2`
line, and the bulk of the type system, the parser and the execution algorithm
are still that work. [LICENSE](LICENSE) keeps the original BSD-3-Clause terms
and the upstream copyright notice, alongside one for the work done on this line;
[AUTHORS.md](AUTHORS.md) says who did what.

Why fork at all. Two reasons, and only the second one still holds:

- Upstream had stopped moving while the projects depending on it had not.
  Development there has since resumed, but by then the two lines had diverged
  far enough that merging back would cost more than it returns.
- The stack was pinned to `angel3_*`, and `angel3_*` decided which `analyzer`
  and which Dart SDK everything downstream could use. That is what held the
  generator seven `analyzer` majors back for months. Cutting the tie was the
  point of the `3` line.

So: the `3` line does not track upstream and does not merge from it. It is
maintained on its own, with three rules - as few dependencies as possible, no
dependency that dictates the SDK, and no behaviour without a test covering it.

### The `3` is a lineage marker, not a version and not a succession

`graphql_server2` is not this package's predecessor. It is its sibling, and it is
alive: 7.0.0 as of August 2026, published by dukefirehawk.com, on its own
numbering that long ago stopped matching the `2` in its name. The `3` here says
only which line this fork was taken from.

If you want the upstream package, take
[`graphql_server2`](https://pub.dev/packages/graphql_server2). Take this one for
the smaller dependency tree and the fixes listed below. They have not been
offered upstream. The two lines were compared at upstream 7.0.0: every release
it has cut since the fork point raises the Dart SDK floor or the linter, and its
dependency set is unchanged.

## What version 3 changed

Four dependencies:
[`graphql_schema3`](https://pub.dev/packages/graphql_schema3),
[`graphql_parser3`](https://pub.dev/packages/graphql_parser3),
[`collection`](https://pub.dev/packages/collection) and
[`stream_channel`](https://pub.dev/packages/stream_channel).

Removed:

- `lib/mirrors.dart`, neither exported nor imported anywhere. It pulled in
  `dart:mirrors`, which rules out AOT compilation, Flutter and the web for
  anyone who happened to import it.
- `angel3_serialize`, whose `Exclude` and `Alias` annotations that file alone
  used; `tuple`, declared and never imported; and `recase`, which served one
  conversion, spelling `__DirectiveLocation` values in screaming snake case,
  now done in place.

Fixed, in execution order rather than order of severity:

- A fragment that spreads itself, directly or through a chain, took the isolate
  down with a `StackOverflowError`. The guard that remembers which fragments
  have been expanded was rebuilt at every level of the recursion instead of
  being shared with it. Forty characters of query were enough to stop a server.
- A response key merged from several selections resolved its field once per
  selection: `{ user { name } user { age } }` called the `user` resolver twice
  and kept the second answer. Every resolver that costs a query was paying that
  twice.
- The shorthand `@skip: true` and `@include: false` did nothing. The directive
  lookup compared the value a directive carried against the directive's own
  name, which no shorthand can satisfy.
- A document holding several operations without an `operationName` reported
  "This document does not define any operations", which describes the opposite
  problem.
- Numeric scalars accept an integer where the schema says `Float`, from a
  literal and from a variable alike.
- Two `@jsonpath` completions were dropped in flight: one nested inside a map,
  one behind any non-nullable field.

Added: 42 tests, where there were none.

### One thing version 3 does not do

A document is executed optimistically and is never validated against the schema
first. An unknown field or an unknown fragment spread yields an empty object,
and an undeclared variable resolves to `null`; none of the three is an error.
Three tests record this, so that changing it stays a deliberate act rather than
an accident.

The full list is in [CHANGELOG.md](CHANGELOG.md).

## Installation

```bash
dart pub add graphql_server3
```


## Ad-hoc Usage

The actual querying functionality is handled by the `GraphQL` class, which takes a schema (from `package:graphql_schema3`). In most cases, you'll want to call `parseAndExecute` on some string of GraphQL text. It returns either a `Stream` or `Map<String, dynamic>`, and can potentially throw a `GraphQLException` (which is JSON-serializable):

```dart
try {
    var data = await graphQL.parseExecute(responseText);

    if (data is Stream) {
        // Handle a subscription somehow...
    } else {
        response.send({'data': data});
    }
} on GraphQLException catch(e) {
    response.send(e.toJson());
}
```

If you're looking for functionality like `graphQLHttp` in `graphql-js`, that is not included in
this package: serving GraphQL over HTTP is specific to the framework you are using.

## Subscriptions

GraphQL queries involving `subscription` operations can return a `Stream`. Ultimately, the transport for relaying subscription events to clients is not specified in the GraphQL spec, so it's up to you.

Note that in a schema like this:

```graphql
type TodoSubscription {
    onTodo: TodoAdded!
}

type TodoAdded {
    id: ID!
    text: String!
    isComplete: Bool
}
```

Your Dart schema's resolver for `onTodo` should be a `Map` *containing an `onTodo` key*:

```dart
field(
  'onTodo',
  todoAddedType,
  resolve: (_, __) {
    return someStreamOfTodos()
            .map((todo) => {'onTodo': todo});
  },
);
```

For the purposes of reusing existing tooling (i.e. JS clients, etc.), `package:graphql_server3` rolls with an implementation of Apollo's
`subscriptions-transport-ws` spec.

**NOTE: At this point, Apollo's spec is extremely out-of-sync with the protocol their client actually expects.**
**See the following issue to track this:**
**<https://github.com/apollographql/subscriptions-transport-ws/issues/551>**

The implementation is built on `package:stream_channel`, and therefore can be used on any two-way transport, whether it is WebSockets, TCP sockets, Isolates, or otherwise.

Users of this package are expected to extend the `Server` abstract class. `Server` will handle the transport and communication, but again, ultimately, emitting subscription events is up to your implementation.

A minimal implementation, running within the context of one single request:

```dart
var channel = IOWebSocketChannel(socket);
var client = stw.RemoteClient(channel.cast<String>());
var server =
    _GraphQLWSServer(client, graphQL, req, res, keepAliveInterval);
await server.done;
```

## Introspection

Introspection of a GraphQL schema allows clients to query the schema itself, and get information about the response the server expects. The `GraphQL` class handles this automatically, so you don't have to write any code for it.

However, you can call the `reflectSchema` method to manually reflect a schema.

## Building a schema from Dart types

Use [`graphql_generator3`](https://pub.dev/packages/graphql_generator3), which reads the
annotations on your classes at build time and emits the matching `GraphQLObjectType`.

The `dart:mirrors` entry point that earlier versions shipped is gone: it ruled out AOT
compilation, Flutter and the web, and nothing used it.
