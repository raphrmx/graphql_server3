
<a alt="ComApps Logo" href="https://comapps.be" target="_blank" rel="noreferrer"><img src="https://www.comapps.be/wp-content/uploads/2026/09/CompleteLogoHorizontalMini.png" style="margin: 15px"></a>

# GraphQL Server 3

[![Build](https://img.shields.io/github/actions/workflow/status/raphrmx/graphql_server3/ci.yml?branch=main&label=build)](https://github.com/raphrmx/graphql_server3/actions/workflows/ci.yml)
[![Pub Version](https://img.shields.io/pub/v/graphql_server3?color=blue)](https://pub.dev/packages/graphql_server3)
[![Maintainer](https://img.shields.io/badge/Maintainer-Raphael_Vrient-purple)](https://pub.dev/publishers/comapps.be/packages)
[![License](https://img.shields.io/badge/Licence-BSD--3--Clause-blue)](LICENSE)
![Maintenance](https://img.shields.io/badge/Maintained-yes-success)
![Null Safety](https://img.shields.io/badge/Null_Safety-passing-success)
![Platforms](https://img.shields.io/badge/Platforms-Android,_iOS,_macOS,_Windows,_Linux,_Web-22375C.svg)

Base package for implementing GraphQL servers. It does not require any specific framework, and
thus can be used in any Dart project.

Execution is permissive by default: a document runs without being checked
against the schema first, which is how this line has always behaved. Pass
`validate: true` for the behaviour the specification describes instead, where a
document that breaks a rule is refused rather than executed. See
[Document validation](#document-validation) for what that covers and what it
does not.

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

## What version 3.3 changed

A document can now be checked against the schema before it is executed, which
the specification requires and which the earlier versions left out on purpose.
It is off unless you ask for it:

```dart
var graphQL = GraphQL(schema, validate: true);
```

Off, nothing changes: an unknown field or fragment still yields an empty object
and an undeclared variable still yields `null`, exactly as in 3.2. Taking this
version therefore changes nothing for a server already running. On, a document
that breaks one of the rules below is refused, and every fault found is
reported together before any resolver runs.

The rules, named as the specification names them:

| Rule | What it refuses |
| --- | --- |
| 5.2.1.1, 5.5.1.1 | An operation or fragment name defined twice, and an anonymous operation sharing a document with another operation. |
| 5.3.1 | A field the type does not declare. |
| 5.3.2 | Two selections written side by side under one response key naming different fields, or the same field with different arguments. |
| 5.3.3 | An object field carrying no selection, and a scalar or enum field carrying one. |
| 5.4.1 | An argument the field does not declare. |
| 5.5.1.2 | A fragment conditioned on a type the schema does not declare, or on a type that is not composite. |
| 5.5.2.1 | A spread naming a fragment the document does not define. |
| 5.5.2.2 | A fragment that spreads itself, directly or through a chain. |
| 5.5.2.3 | A fragment spread where no possible type of the parent could match its condition. |
| 5.8.3 | A variable the operation does not declare, including one used inside a fragment it spreads. |

Every fault found is reported together, before any resolver runs.

Two rules are left out on purpose. Directives are not checked against the
schema (5.7.1), because this package carries application directives such as
`@jsonpath` and refusing whatever a schema does not declare would break a
consumer over a directive it owns. A fragment a document declares without
spreading it is accepted (5.5.1.4), because it harms nobody.

Three limits are worth knowing. Argument values are checked during execution
rather than here, where coercion already refuses a missing or mistyped one.
Selection merging compares selections written side by side, not ones a fragment
brings together. And a fragment spread is refused only when no possible type of
its parent could match, which mirrors what the executor decides at run time
rather than the stricter nominal rule.

One behaviour changes for a schema built with `introspect: false`: `__schema`
and `__type` are now refused as fields the query type does not declare, where
they used to answer an empty object.

The `subscriptions-transport-ws` implementation was fixed on three points:

- `stop` is handled. A running subscription is held against its operation id,
  cancelled when the client asks for it, and cancelled again when the
  connection is terminated. Before, the message was read and dropped, so a
  client could not unsubscribe and events kept being pushed until the socket
  closed.
- A malformed `start`, and an `onOperation` that throws, answer an `error`
  message naming the operation. Before, both left an unhandled asynchronous
  error, since a stream ignores the future its callback returns.
- `OperationMessage.legacyGql*` is gone. Those ten constants were character for
  character the ten they sat beside.

`graphql_ws.dart` is new: a server speaking `graphql-transport-ws`, the
protocol a current Apollo Client or urql expects. The older
`subscriptions-transport-ws` server stays, and both are described under
[Subscriptions](#subscriptions).

Added: 59 tests, 31 of them on the two subscription layers, which had none.

## What version 3.0 changed

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

### One thing version 3.0 did not do

A document was executed optimistically and never validated against the schema.
An unknown field or an unknown fragment spread yielded an empty object, and an
undeclared variable resolved to `null`. Version 3.3 reports all three when it
is asked to.

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

## Document validation

With `validate: true`, `parseAndExecute` checks the document against the
schema before running it and throws a `GraphQLException` carrying every fault
it found. The errors each name a line and a column, so a client can point at
the text that caused them.

To check a document without running it, parse it and call `validateDocument`,
which answers the same errors as a list:

```dart
var document = Parser(scan(text)).parseDocument();
var errors = graphQL.validateDocument(document);

if (errors.isEmpty) {
    var data = await graphQL.executeRequest(schema, document);
}
```

The flag defaults to off because a client whose document the schema refuses
stops working the moment it goes on, and a running server cannot know what its
clients send. Turn it on once you do. Checking a document without executing it,
as above, is a way to find out: it answers the errors and runs nothing.

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

### Two protocols carry subscriptions, and this package speaks both

| | `subscriptions_transport_ws.dart` | `graphql_ws.dart` |
| --- | --- | --- |
| Handshake token | `graphql-ws` | `graphql-transport-ws` |
| Defined by | Apollo's `subscriptions-transport-ws`, no longer maintained | the [`graphql-ws`](https://github.com/enisdenjo/graphql-ws) library |
| Class to extend | `Server` | `GraphQLWsServer` |
| Start an operation | `start` | `subscribe` |
| One result | `data` | `next` |
| Client ends one | `stop` | `complete` |
| Keep-alive | `ka`, server to client | `ping` and `pong`, either way |
| Refusing a connection | a `connection_error` message | a close code |

The two tokens are worth reading twice. The older library is named
`subscriptions-transport-ws` and negotiates `graphql-ws`; the newer library is
named `graphql-ws` and negotiates `graphql-transport-ws`.

A current Apollo Client or urql speaks the newer protocol by default. The older
one is what earlier clients speak, and Apollo's own spec for it drifted from
what their client expects, which
[issue 551](https://github.com/apollographql/subscriptions-transport-ws/issues/551)
tracks.

Both are built on `package:stream_channel`, so either can be used on any
two-way transport: WebSockets, TCP sockets, isolates, or anything else. Extend
`Server` or `GraphQLWsServer`, answer `onConnect` and `onOperation`, and how
subscription events are emitted stays yours.

```dart
var channel = IOWebSocketChannel(socket);
var server = MyGraphQLWsServer(GraphQLWsClient(channel.cast<String>()));
await server.done;
```

A client says which protocol it wants in the `Sec-WebSocket-Protocol` header of
the handshake. This package does not own the socket, so that choice belongs to
whatever serves it: read the header, then hand the channel to the matching
server. `GraphQLWsMessage.subprotocol` holds the token to compare against.

For the same reason, `GraphQLWsServer` cannot close a socket with a code, and
the newer protocol reports a refusal with one rather than with a message.
Override `onClose` to pass it on, or the reason is lost:

```dart
@override
FutureOr<void> onClose(int code, String reason) {
    socket.close(code, reason);
}
```

The codes are in `GraphQLWsCloseCode`: `forbidden` for a connection `onConnect`
refused, `unauthorized` for an operation that arrived before the handshake
finished, `subscriberAlreadyExists` for an operation id used twice, and
`badRequest` for a message the protocol cannot read.

## Introspection

Introspection of a GraphQL schema allows clients to query the schema itself, and get information about the response the server expects. The `GraphQL` class handles this automatically, so you don't have to write any code for it.

However, you can call the `reflectSchema` method to manually reflect a schema.

## Building a schema from Dart types

Use [`graphql_generator3`](https://pub.dev/packages/graphql_generator3), which reads the
annotations on your classes at build time and emits the matching `GraphQLObjectType`.

The `dart:mirrors` entry point that earlier versions shipped is gone: it ruled out AOT
compilation, Flutter and the web, and nothing used it.
