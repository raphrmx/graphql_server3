# Change Log

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
