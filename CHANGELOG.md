# Change Log

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
