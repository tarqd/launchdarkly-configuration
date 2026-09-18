"""Helpers shared by run-vectors.py and validate.py."""

import re

SUBST = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}")

# Marks a whole-scalar substitution of an unset variable with no default. Requirement 1.3.7
# leaves such a property absent rather than setting it to an empty string, so the containing
# mapping or sequence drops it.
ABSENT = object()


def substitute(node, env):
    """Apply Requirement 1.3.x environment variable substitution to a parsed document.

    Whole-scalar substitution only; the typing rule in Requirement 1.3.5 needs schema context
    and is applied by the caller. `$${` escapes to a literal `${` per Requirement 1.3.8.
    """
    if isinstance(node, dict):
        out = {}
        for key, value in node.items():
            value = substitute(value, env)
            if value is not ABSENT:
                out[key] = value
        return out
    if isinstance(node, list):
        return [v for v in (substitute(v, env) for v in node) if v is not ABSENT]
    if not isinstance(node, str):
        return node

    guarded = node.replace("$${", "\x00")
    match = SUBST.fullmatch(guarded)
    if match and match.group(2) is None and not env.get(match.group(1)):
        return ABSENT

    def replace(m):
        value = env.get(m.group(1))
        return value if value else (m.group(2) or "")

    return SUBST.sub(replace, guarded).replace("\x00", "${")


def pointers_for(error):
    """Every property pointer a single validation error can be said to name.

    Two things make this more than `error.absolute_path`. A closed object reports an unexpected
    or missing property on the *parent*, with the property name only in the message. And a
    `type`-discriminated union reports on the union node, with the branch errors nested in
    `error.context` — so the leaf that actually failed has to be recovered from there. An SDK
    satisfying Requirement 1.6.4 has to do the same work; a validator's default output is not
    specific enough on its own.
    """
    base = "/" + "/".join(str(p) for p in error.absolute_path)
    found = {base}
    for pattern in (r"'([^']+)' was unexpected", r"'([^']+)' is a required property"):
        for name in re.findall(pattern, error.message):
            found.add(f"{base.rstrip('/')}/{name}")
    for sub in error.context or ():
        # Errors from a branch whose discriminator did not match describe a document the author
        # never wrote, so their pointers would be misleading.
        if "is not one of" in sub.message or "was expected" in sub.message:
            continue
        # Context errors already carry absolute instance paths, so they are not re-prefixed.
        found |= pointers_for(sub)
    return found
