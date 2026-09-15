# Change Log

## 3.3.0

### Added
- `GraphQL(schema, validate: true)` checks a document against the schema
  before executing it, which the specification requires and which this package
  did not do. `parseAndExecute` and `executeRequest` then throw a
  `GraphQLException` carrying every fault found, before any resolver runs.
  `validateDocument` answers the same errors for a parsed document without
  running it, whichever way the flag is set.
- The flag is off by default, so this version changes nothing for a server that
  takes it without asking. Off, an unknown field or fragment still yields an
  empty object and an undeclared variable still yields `null`, as in 3.2.
- The rules applied are 5.2.1.1 and 5.5.1.1 (an operation or fragment name is
  defined once, and an anonymous operation stands alone), 5.3.1 (a field is
  declared by the type it is selected on), 5.3.2 (two selections written side
  by side under one response key name the same field with the same arguments),
  5.3.3 (an object field carries a selection and a leaf field carries none),
  5.4.1 (a field's arguments are declared by that field), 5.5.1.2 (a fragment
  conditions on a composite type the schema declares), 5.5.2.1 (a spread names
  a fragment the document defines), 5.5.2.2 (no fragment spreads itself),
  5.5.2.3 (a fragment is spread somewhere it can apply) and 5.8.3 (every
  variable used is declared by its operation, through a fragment included).
- Two rules are left out on purpose: 5.7.1, because this package carries
  application directives such as `@jsonpath` and refusing whatever a schema
  does not declare would break a consumer over a directive it owns, and
  5.5.1.4, because a fragment declared and not spread harms nobody.
- 59 tests, 31 of them on the two subscription layers, which had none.

### Added, continued
- `graphql_ws.dart` serves the `graphql-transport-ws` protocol, which is what a
  current Apollo Client or urql speaks by default. `GraphQLWsServer` asks for
  the same two decisions as the older `Server`, so a server can be moved from
  one protocol to the other without rewriting what it answers, and both can be
  served side by side: the `Sec-WebSocket-Protocol` header of the handshake
  says which one a client wants.
- The newer protocol reports a refusal with a WebSocket close code rather than
  with a message. This package does not own the socket, so `GraphQLWsServer`
  hands the code to `onClose`, which a WebSocket transport overrides. The codes
  are named in `GraphQLWsCloseCode`.
- `connectionInitWaitTimeout` closes a connection whose `connection_init` never
  arrives.
- `GraphQLResult` moved to its own file, because both transports answer with
  it. It is still exported from `subscriptions_transport_ws.dart`, so nothing
  moved for a consumer.

### Fixed
- `stop` is handled. A running subscription is held against its operation id,
  cancelled when the client asks for it, and cancelled again when the connection
  is terminated. The message was read and dropped, so a client could not
  unsubscribe and events kept being pushed until the socket closed.
- A malformed `start`, and an `onOperation` that throws, answer an `error`
  message naming the operation. Both used to leave an unhandled asynchronous
  error, since a stream ignores the future its callback returns. A single
  malformed frame could therefore take down more than the operation it named.
- `connection_terminate` completes `done` and cancels the keep-alive timer. It
  cancelled the message subscription, which stops `onDone` from ever running.
- The licence badge in the README said MIT. The licence is BSD-3-Clause, as the
  paragraph below the badge already said.

### Deprecated
- `OperationMessage.legacyGqlConnectionInit` and the nine constants beside it.
  Each holds the constant it is named after, character for character, so the
  pair never carried two different values. They go in 4.0.0.

### What changes when you turn validation on
- A document that names an unknown field, an unknown argument or an unknown
  fragment, that puts two different selections under one response key, that
  spreads a fragment where it can never apply, or that uses an undeclared
  variable, is refused instead of answering an empty object, a `null`, or an
  answer quietly missing one of its keys. A client sending such a document
  stops working, so find out what your clients send before you switch.
- With `introspect: false`, `__schema` and `__type` are refused as fields the
  query type does not declare. They used to answer an empty object.

## 3.2.2

### Changed
- `LICENSE` carries a copyright notice for the work done on this line, next to
  the upstream one it has always kept, as the BSD-3-Clause terms require.
  `AUTHORS.md` already recorded who did what; the licence file now says the same
  thing.
- The README says where to look for both, rather than describing the licence
  file as untouched.
- The README links each dependency to its pub.dev page. The pointer between
  these packages went to GitHub, which is the wrong destination from a pub.dev
  page.

No code changed.

## 3.2.1

### Added
- Documentation for the whole public API. It stood at 16 of 98 elements, which
  is below the 20% pub.dev asks for, and the part that was missing was the part
  a reader needs: every method of [GraphQL], the Apollo subscription classes,
  and the two libraries themselves. Each method now says what it answers and
  what it throws, and `parseAndExecute` says plainly that the document is never
  validated against the schema first.
- The `public_member_api_docs` lint, so that this cannot quietly come back. The
  package analyzes clean with it on.

### Changed
- The `__TypeKind` values are a named constant rather than a list written inside
  the call that builds the type. Inlined, that call sat exactly on the boundary
  where two releases of `dart_style` disagree about where to break, so the file
  reformatted itself according to which SDK ran and `dart format
  --set-exit-if-changed` failed on CI while passing locally. Both formatters
  agree on the named form.

No behaviour changed.

## 3.2.0

First release published to pub.dev. `graphql_schema3` and `graphql_parser3` are
now hosted dependencies rather than git ones, which is what publishing requires
and what lets a consumer resolve the whole stack from pub.

### Fixed
- A fragment that spreads itself, directly or through a chain, no longer takes
  the isolate down. The guard that remembers which fragments have been expanded
  was rebuilt at every level of the recursion instead of being shared with it,
  so `fragment f on User { name ...f }` recursed until the stack ran out. Forty
  characters of query were enough to stop the server.
- A response key merged from several selections resolves its field once.
  `{ user { name } user { age } }` groups two selections under `user` and used
  to call the `user` resolver twice, once per selection, keeping the second
  answer. Every resolver that costs a query was paying that twice.
- `@skip: true` and `@include: false` in their shorthand form now do what they
  say. The directive lookup compared the *value* a directive carried against
  the directive's own name, which no shorthand can ever satisfy, so the field
  was rendered regardless. Directives are matched on their name.
- A document holding several operations without an `operationName` said "This
  document does not define any operations", which describes the opposite
  problem. The two cases are told apart.
- `makeLazy` threw away the result of its own recursion, so a `@jsonpath`
  variable sitting inside a nested map was never completed; and `completeValue`
  dropped the pending list when it unwrapped a non-nullable type, losing the
  same completions behind any `T!` field.

### Changed
- `GraphQL.collectFields` takes its `visitedFragments` guard as a `Set<String?>`
  rather than a `List`. It is public, so this is a breaking signature, but it is
  an implementation detail of the execution algorithm and passing it explicitly
  was never useful.

### Added
- Tests for directives, variables and their defaults, aliases, merged selection
  sets, lists, nulls, mutations, resolver failures, operation selection and
  fragment cycles. 42 in all, and three of them record, deliberately, that a
  document is executed without ever being validated against the schema: an
  unknown field or fragment yields an empty object and an undeclared variable
  resolves to null, rather than raising an error.

## 3.1.0

### Removed
- `lib/mirrors.dart`, which was neither exported nor imported anywhere. It also
  pulled in `dart:mirrors`, which rules out AOT compilation, Flutter and the
  web for anyone who happened to import it.
- The `angel3_serialize` dependency, whose `Exclude` and `Alias` annotations
  were used by that file alone.
- The `tuple` dependency: declared, never imported.
- The `recase` dependency. It served a single conversion, spelling
  `__DirectiveLocation` values in screaming snake case, now done in place.

### Fixed
- Numeric scalars accept an integer where the schema says `Float`. The
  specification coerces in that direction, and a decoded body hands over an
  `int`, so `sum(value: 4)` used to fail with a cast error both from a literal
  and from a variable.

### Added
- A test suite. There was none.

## 3.0.0

* Initial release
