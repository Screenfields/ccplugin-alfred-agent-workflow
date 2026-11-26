#!/usr/bin/env python3
"""Fail on a bare mid-test `!` in bats files (CCW-148).

Why: bats runs each test under errexit, but errexit does not trip on a negated
command (`! cmd`) that is not the last command of the test. A bare mid-test
`! cmd` therefore never fails, so the assertion is decoration.

Rule (the one home of it; tested on bats 1.8.2):
  Accepted:  run ! cmd
             ! cmd || false
             if cmd; then false; fi
             a bare `!` as the last command of a @test body or helper function
             (its status is the status of the test or function)
  Flagged:   a bare `!` at the start of a command, or after ;  &&  ||  then
             do  else, when it is neither the last command nor directly
             followed by `|| false`. `|| true`, `|| :`, `|| return 1` and
             `&& false` are not accepted.
  Not a command start, so not flagged: [ ! -f f ], [[ ! x ]], if ! cmd,
  while ! cmd, $(...), run ! cmd, and a `!` inside a quoted string, a
  comment or a heredoc body.
  Helper functions (setup, teardown, any name() { at column 0) follow the
  same rule as @test bodies. A `!` outside any test or function is not
  checked.

Usage: bats-negation.py [file ...]
  No arguments: tests/*.bats and tests/*/*.bats relative to the cwd.
  Explicit paths replace the globs.
Exit: 0 clean, 1 findings, 2 parse, usage or no-file error (fails closed).
"""
import bisect
import glob
import re
import sys

MESSAGE = ("bare `!` is not the last command, so errexit ignores it and it can "
           "never fail; use `run ! cmd`, `! cmd || false` or "
           "`if cmd; then false; fi`")


class ParseError(Exception):
    pass


def logical_lines(text, path):
    """Return [(masked_text, marks, col0)] per logical command line.

    Quoted content is masked to 'x', comments and heredoc bodies are dropped,
    backslash and trailing-operator (| && ||) continuations are joined, and
    `marks` maps character offsets to physical line numbers. Length is
    preserved 1:1 between the masked text and its marks.
    """
    lines = text.split('\n')
    n = len(lines)
    out = []
    i = 0
    q = None
    qline = 0
    cur = ''
    marks = []
    col0 = False
    started = False
    pending = []
    while i < n:
        ln = lines[i]
        lineno = i + 1
        if not started:
            started = True
            col0 = bool(ln) and not ln[0].isspace()
        marks.append((len(cur), lineno))
        buf = ''
        cont = False
        j = 0
        L = len(ln)
        while j < L:
            c = ln[j]
            if q == "'":
                if c == "'":
                    q = None
                    buf += "'"
                else:
                    buf += 'x'
                j += 1
                continue
            if q in ('"', "$'"):
                if c == '\\' and j + 1 < L:
                    buf += 'xx'
                    j += 2
                    continue
                if c == q[-1]:
                    q = None
                    buf += c
                else:
                    buf += 'x'
                j += 1
                continue
            if c == '\\':
                if j == L - 1:
                    cont = True
                    j += 1
                    continue
                buf += 'xx'
                j += 2
                continue
            if c == "'":
                q, qline = "'", lineno
                buf += c
                j += 1
                continue
            if c == '"':
                q, qline = '"', lineno
                buf += c
                j += 1
                continue
            if c == '$' and ln[j + 1:j + 2] == "'":
                q, qline = "$'", lineno
                buf += "$'"
                j += 2
                continue
            if c == '#' and (not buf or buf[-1] in ' \t;&|('):
                break
            if c == '<' and ln[j:j + 3] == '<<<':
                buf += '<<<'
                j += 3
                continue
            if c == '<' and ln[j:j + 2] == '<<' and not re.search(r'\(\([^)]*$', buf):
                m = re.match(r'<<(-?)[ \t]*(?:"([^"]*)"|\'([^\']*)\'|\\?([A-Za-z_][A-Za-z0-9_]*))', ln[j:])
                if m:
                    d = m.group(2) or m.group(3) or m.group(4)
                    pending.append((d, m.group(1) == '-', lineno))
                    buf += 'HEREDOC'
                    j += m.end()
                    continue
            buf += c
            j += 1
        cur += buf
        i += 1
        if q is not None or cont:
            cur += ' '
        if q is None and pending:
            for d, strip, hline in pending:
                while True:
                    if i >= n:
                        raise ParseError('%s:%d: unterminated heredoc %r (no closing delimiter)' % (path, hline, d))
                    body = lines[i]
                    i += 1
                    if (body.lstrip('\t') if strip else body) == d:
                        break
            pending = []
        if q is None and not cont:
            s = cur.rstrip()
            if s.endswith(('|', '&&', '||')) and i < n:
                cur += ' '
                continue
            if s.endswith(('|', '&&', '||')):
                raise ParseError('%s:%d: unterminated continuation at end of file' % (path, marks[0][1]))
            if s.strip():
                out.append((cur.replace('\t', ' '), marks, col0))
            cur = ''
            marks = []
            started = False
    if q is not None:
        raise ParseError('%s:%d: unterminated quote' % (path, qline))
    if cur.strip():
        raise ParseError('%s:%d: unterminated continuation at end of file' % (path, marks[0][1]))
    return out


def mask_nested(s):
    """Blank the inside of $(...), `...`, [[ ... ]] and (( ... )), same length."""
    out = list(s)
    n = len(s)
    i = 0
    while i < n:
        c = s[i]
        boundary = i == 0 or s[i - 1] in ' \t;&|(!'
        if (c == '$' and s[i + 1:i + 2] == '(') or (c == '(' and s[i + 1:i + 2] == '(' and boundary):
            j = i + 1 if c == '$' else i
            d = 0
            while j < n:
                if s[j] == '(':
                    d += 1
                elif s[j] == ')':
                    d -= 1
                    if d == 0:
                        break
                j += 1
            for k in range(i + 2, min(j, n)):
                out[k] = 'x'
            i = j + 1
            continue
        if c == '`':
            j = s.find('`', i + 1)
            if j < 0:
                j = n
            for k in range(i + 1, j):
                out[k] = 'x'
            i = j + 1
            continue
        if c == '[' and s[i + 1:i + 2] == '[' and boundary:
            j = s.find(']]', i + 2)
            if j < 0:
                j = n
            for k in range(i + 2, j):
                out[k] = 'x'
            i = j + 2
            continue
        i += 1
    return ''.join(out)


SEP = re.compile(r';;|;|&&|\|\||\n')
LEAD = re.compile(r'(?:then|do|else|\{)(?:\s+|$)')
BANG = re.compile(r'!(?:\s|$)')
CLOSERS = {'fi', 'done', 'esac', '}', ')'}


def statements(text, marks):
    """Yield (lineno, stmt_text, sep) for each simple statement of one logical line."""
    text = mask_nested(text)
    offsets = [m[0] for m in marks]
    pos = 0
    sep = ''
    pieces = []
    for m in SEP.finditer(text):
        pieces.append((pos, text[pos:m.start()], sep))
        pos, sep = m.end(), m.group()
    pieces.append((pos, text[pos:], sep))
    for start, piece, sp in pieces:
        stripped = piece.lstrip()
        start += len(piece) - len(stripped)
        stripped = stripped.rstrip()
        while True:
            m = LEAD.match(stripped)
            if not m:
                break
            start += m.end()
            stripped = stripped[m.end():]
        if not stripped:
            continue
        lineno = marks[max(bisect.bisect_right(offsets, start) - 1, 0)][1]
        yield lineno, stripped, sp


def check_block(stmts):
    """stmts: [(lineno, text, sep)] of one test or function body. Return finding line numbers."""
    found = []
    for k, (lineno, t, _sep) in enumerate(stmts):
        if not BANG.match(t):
            continue
        nxt = stmts[k + 1] if k + 1 < len(stmts) else None
        if nxt and nxt[2] == '||':
            if nxt[1] == 'false':
                continue
            found.append(lineno)
            continue
        # `a && ! b && ! c` as the last command: a failing `!` stops the chain,
        # so the chain's status is the test's or function's status.
        j = k
        while j + 1 < len(stmts) and stmts[j + 1][2] == '&&':
            j += 1
        if all(s[1] in CLOSERS for s in stmts[j + 1:]):
            continue
        found.append(lineno)
    return found


TEST_HEAD = re.compile(r'@test\s+(?:"[^"]*"|\'[^\']*\'|\S+)\s*\{(.*)$')
FUNC_HEAD = re.compile(r'(?:function\s+[A-Za-z_][\w:.-]*(?:\s*\(\))?|[A-Za-z_][\w:.-]*\s*\(\))\s*\{(.*)$')
ONE_LINE = re.compile(r'^(.*?)[;\s]\s*\}\s*$')


def check_file(path):
    with open(path, encoding='utf-8') as fh:
        text = fh.read()
    ll = logical_lines(text, path)
    findings = []
    i = 0
    N = len(ll)
    while i < N:
        s, marks, col0 = ll[i]
        s = s.strip()
        m = (TEST_HEAD.match(s) or FUNC_HEAD.match(s)) if col0 else None
        if not m:
            i += 1
            continue
        hline = marks[0][1]
        kind = 'test' if s.startswith('@test') else 'function'
        rest = m.group(1)
        one = ONE_LINE.match(rest + ' ') if rest.strip() else None
        body = []
        if one:
            body.append((one.group(1), [(0, hline)]))
            i += 1
        else:
            if rest.strip():
                body.append((rest, [(0, hline)]))
            i += 1
            while i < N and not (ll[i][2] and ll[i][0].strip() == '}'):
                body.append((ll[i][0], ll[i][1]))
                i += 1
            if i >= N:
                raise ParseError('%s:%d: %s has no closing } at column 0' % (path, hline, kind))
            i += 1
        stmts = []
        for btext, bmarks in body:
            stmts.extend(statements(btext, bmarks))
        findings.extend(check_block(stmts))
    return findings


def main(argv):
    files = argv
    if not files:
        files = sorted(set(glob.glob('tests/*.bats') + glob.glob('tests/*/*.bats')))
        if not files:
            print('bats-negation: no tests/*.bats or tests/*/*.bats files found '
                  'under %s (run from the repo root)' % glob.os.getcwd(), file=sys.stderr)
            return 2
    rc = 0
    count = 0
    total = 0
    for f in files:
        try:
            found = check_file(f)
        except (ParseError, OSError, UnicodeDecodeError) as e:
            print('bats-negation: ERROR %s' % (e if isinstance(e, ParseError) else '%s: %s' % (f, e)),
                  file=sys.stderr)
            rc = 2
            continue
        count += 1
        for lineno in found:
            print('%s:%d: %s' % (f, lineno, MESSAGE))
        total += len(found)
        if found and rc == 0:
            rc = 1
    print('bats-negation: checked %d file(s), %d finding(s)' % (count, total))
    return rc


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
