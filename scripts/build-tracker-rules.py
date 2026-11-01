#!/usr/bin/env python3
"""Converts EasyPrivacy (https://easylist.to, CC BY-SA 3.0) into Kage's bundled tracker-domain list.

Only whole-host blocking rules are kept: `||host^` optionally followed by `$third-party` or by
resource-type options. Rules with paths, wildcards, `domain=` scoping, exceptions (`@@`) or element
hiding (`##`) are dropped, because Kage turns each host into one WebKit `url-filter` (ContentRuleBuilder).

Usage: build-tracker-rules.py <easyprivacy.txt> <output.txt>
"""
import datetime
import re
import sys

HOST = re.compile(r"^\|\|([a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+)\^(?:\$(.*))?$")
ALLOWED_OPTIONS = {"third-party", "3p", "script", "image", "xmlhttprequest", "ping", "subdocument", "other", "media", "font", "stylesheet", "websocket"}


def convert(lines):
    version = None
    hosts = set()
    for raw in lines:
        line = raw.strip()
        if line.startswith("! Version:"):
            version = line.split(":", 1)[1].strip()
        if not line or line.startswith("!") or line.startswith("[") or line.startswith("@@") or "#" in line:
            continue
        m = HOST.match(line.lower())
        if not m:
            continue
        options = m.group(2)
        if options:
            opts = {o.strip() for o in options.split(",")}
            if not opts <= ALLOWED_OPTIONS:
                continue
        hosts.add(m.group(1))
    # Drop hosts already covered by a parent domain in the list (the filter matches subdomains too).
    kept = sorted(h for h in hosts if not any(h.endswith("." + h.split(".", i)[-1]) and h.split(".", i)[-1] in hosts
                                              for i in range(1, h.count("."))))
    return version, kept


def main():
    src, dst = sys.argv[1], sys.argv[2]
    with open(src, encoding="utf-8") as f:
        version, hosts = convert(f)
    if len(hosts) < 1000:
        sys.exit(f"only {len(hosts)} hosts parsed; refusing to write a suspiciously small list")
    today = datetime.date.today().isoformat()
    with open(dst, "w", encoding="utf-8") as f:
        f.write("! Kage tracker hosts, derived from EasyPrivacy\n")
        f.write("! Source: https://easylist.to/easylist/easyprivacy.txt\n")
        f.write(f"! EasyPrivacy version: {version or 'unknown'}; converted {today} by scripts/build-tracker-rules.py\n")
        f.write("! Licence: Creative Commons Attribution-ShareAlike 3.0 (https://creativecommons.org/licenses/by-sa/3.0/)\n")
        f.write("! Copyright: The EasyList authors (https://easylist.to/). This derived list is shared under the same licence.\n")
        for h in hosts:
            f.write(h + "\n")
    print(f"{len(hosts)} hosts written to {dst}")


if __name__ == "__main__":
    main()
