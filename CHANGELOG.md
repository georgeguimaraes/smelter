# Changelog

## [0.1.2](https://github.com/georgeguimaraes/smelter/compare/v0.1.1...v0.1.2) (2026-02-17)


### Bug Fixes

* **ci:** publish to hex directly from release-please workflow ([3c07432](https://github.com/georgeguimaraes/smelter/commit/3c07432cf02b4186849fa6471b0134393da540f9))


### Miscellaneous

* **deps-dev:** bump credo from 1.7.15 to 1.7.16 ([#4](https://github.com/georgeguimaraes/smelter/issues/4)) ([20a16e4](https://github.com/georgeguimaraes/smelter/commit/20a16e4a69c25e5a47cce1b56fdf5f89b01fa259))
* **deps-dev:** bump ex_doc from 0.40.0 to 0.40.1 ([#5](https://github.com/georgeguimaraes/smelter/issues/5)) ([164409e](https://github.com/georgeguimaraes/smelter/commit/164409ee496211d563e637c0b7c10ca7dd147ffe))
* remove unused on-release workflow ([eed15c4](https://github.com/georgeguimaraes/smelter/commit/eed15c4c3ef42996cce932e205b42df4552d4514))

## [0.1.1](https://github.com/georgeguimaraes/smelter/compare/v0.1.0...v0.1.1) (2026-01-26)


### Bug Fixes

* preserve context isolation when resolving sibling schemas ([862b713](https://github.com/georgeguimaraes/smelter/commit/862b713cb58585dff5f7fe9c44d52fc17cace969))
* remove trailing whitespace from moduledoc blank lines ([564bd36](https://github.com/georgeguimaraes/smelter/commit/564bd36b744ab8fe946c9cb2dde48e3f5d1612cd))


### Miscellaneous

* bump version to 0.1.1 ([263f967](https://github.com/georgeguimaraes/smelter/commit/263f9679df57a2da0529363bc90250e4bd2ec8ff))
* **deps-dev:** bump ex_doc from 0.39.3 to 0.40.0 ([#1](https://github.com/georgeguimaraes/smelter/issues/1)) ([69dd467](https://github.com/georgeguimaraes/smelter/commit/69dd467ef67216cbb3d53d730d4828469b9ff558))


### Tests

* add coverage for context isolation and root self-reference ([9c64b40](https://github.com/georgeguimaraes/smelter/commit/9c64b402f4f28f4f8d52dc8598f7f487782dba08))

## [0.1.0] - 2026-01-20

### Features

- Initial release
- JSON Schema parsing with `$ref` resolution
- Schema composition support (`allOf`, `oneOf`, `anyOf`)
- Enum and const handling
- Format specifiers (date-time, uri, email, uuid)
- Ecto.Schema code generation with changeset/2
