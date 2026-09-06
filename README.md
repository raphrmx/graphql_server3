# GraphQL Server 3

[![Build](https://img.shields.io/github/actions/workflow/status/raphrmx/graphql_server3/ci.yml?branch=main&label=build)](https://github.com/raphrmx/graphql_server3/actions/workflows/ci.yml)
[![Maintainer](https://img.shields.io/badge/Maintainer-Raphael-purple)](https://comapps.be)
[![License](https://img.shields.io/badge/Licence-BSD--3--Clause-blue)](LICENSE)

Base package for implementing GraphQL servers. It does not require any specific framework, and
thus can be used in any Dart project.

## Installation

These packages are not published on pub.dev. Depend on the repository:

```yaml
dependencies:
  graphql_server3:
    git: https://github.com/raphrmx/graphql_server3.git
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

Use [`graphql_generator3`](https://github.com/raphrmx/graphql_generator3), which reads the
annotations on your classes at build time and emits the matching `GraphQLObjectType`.

The `dart:mirrors` entry point that earlier versions shipped is gone: it ruled out AOT
compilation, Flutter and the web, and nothing used it.
