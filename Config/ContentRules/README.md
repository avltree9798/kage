# Content-blocking rules (ticket K-21)

Kage blocks trackers with EasyPrivacy's whole-host rules.

- Source: https://easylist.to/easylist/easyprivacy.txt, by the EasyList authors.
- Licence: Creative Commons Attribution-ShareAlike 3.0 (https://creativecommons.org/licenses/by-sa/3.0/).
  EasyPrivacy is dual-licensed GPLv3 / CC BY-SA 3.0; Kage uses it under CC BY-SA 3.0, which permits bundling in
  an app with attribution. The derived host list stays under CC BY-SA 3.0. Kage's code is not affected.
- Bundled file: `Packages/SecurityKit/Sources/SecurityKit/Resources/easyprivacy-hosts.txt`. Its header records the
  EasyPrivacy version and conversion date.
- Converter: `scripts/build-tracker-rules.py`. It keeps only `||host^` rules (optionally `$third-party` or
  resource-type options), drops path, wildcard, `domain=`-scoped, exception and cosmetic rules, and removes hosts
  covered by a parent host.
- Validation: SecurityKit's tests check every host's syntax and the attribution header, and compile the full ruleset
  with WebKit's real `WKContentRuleListStore` in Standard and Strict modes.
- Updates: CI's `tracker-rules` job rebuilds the list from upstream on every run and reports how far the bundled
  copy has drifted. Refresh it before each release.

Attribution is also shown in Settings > About.
