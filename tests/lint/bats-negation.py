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
             do  else  ( {  or a case arm pattern, when it is neither the last
             command nor directly followed by `|| false`. `|| true`, `|| :`,
             `|| return 1` and `&& false` mid-test are not accepted. After
             `! x || false`, a following `||` is flagged anywhere and a
             following `&&` mid-test; `! x || false && y` as the last command
             is accepted (the false's status is the test's).
  "Last" is decided per enclosing block: a `!` inside `if`, `case`, a loop or
  a `{ }` group is accepted only when that compound is itself the last
  command, and then only as the last command of its branch or arm. A `!`
  last in a `( )` subshell is accepted wherever the subshell stands, because
  a failing subshell trips errexit itself; a `!` mid-subshell is flagged.
  Not a command start, so not flagged: [ ! -f f ], [[ ! x ]], if ! cmd,
  while ! cmd, $(...), run ! cmd, and a `!` inside a quoted string, a
  comment or a heredoc body.
  Helper functions (setup, teardown, any name() { or name() with the { alone
  on the next line, at column 0) follow the same rule as @test bodies. A `!`
  outside any test or function is not checked.

Known limits (not coded; bats 1.8.2 behaviour):
  - A test whose `{` is on the next line (`@test "x"` then `{`) is not a test
    to bats (it prints `1..0` or fails the file), so its `!` never runs and
    the lint does not read it. Put `{` on the @test line.
  - A `!` that is last inside a multi-line `$(` ... `)` assignment is flagged
    although bats enforces it for a plain `out=$(`. Write `! cmd || false`
    there. The same `!` under `local out=$(` is vacuous, and flagged rightly.

Usage: bats-negation.py [file ...]
  No arguments: tests/*.bats and tests/*/*.bats relative to the cwd.
  Explicit paths replace the globs.
Exit: 0 clean, 1 findings, 2 parse, usage or no-file error (fails closed).
"""
import bisect
import glob
import os
import re
import sys

MESSAGE = ("bare `!` is not the last command, so errexit ignores it and it can "
           "never fail; use `run ! cmd`, `! cmd || false` or "
           "`if cmd; then false; fi`")


class ParseError(Exception):
    pass


def in_arith(buf):
    """True when the end of buf is inside `((` ... `))` (so `<<` is a shift)."""
    st = []
    i = 0
    while i < len(buf):
        if buf.startswith('((', i):
            st.append('A')
            i += 2
            continue
        if buf[i] == '(':
            st.append('P')
        elif buf[i] == ')' and st:
            top = st.pop()
            if top == 'A' and buf[i + 1:i + 2] == ')':
                i += 1
        i += 1
    return 'A' in st


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
    stack = []
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
            if stack:
                # Inside a quote. Quoted text is masked to 'x'; a quote that
                # opens inside "$( ... )" nests, so its characters stay masked
                # until the outermost quote closes.
                top = stack[-1]
                if top[0] == "'":
                    if c == "'":
                        stack.pop()
                        buf += "'" if not stack else 'x'
                    else:
                        buf += 'x'
                    j += 1
                elif top[0] == '"':
                    if c == '\\' and j + 1 < L:
                        buf += 'xx'
                        j += 2
                    elif c == '"':
                        stack.pop()
                        buf += '"' if not stack else 'x'
                        j += 1
                    elif c == '$' and ln[j + 1:j + 2] == '(':
                        stack.append(['cmd', 1])
                        buf += 'xx'
                        j += 2
                    else:
                        buf += 'x'
                        j += 1
                elif top[0] == "$'":
                    if c == '\\' and j + 1 < L:
                        buf += 'xx'
                        j += 2
                    else:
                        if c == "'":
                            stack.pop()
                            buf += "'" if not stack else 'x'
                        else:
                            buf += 'x'
                        j += 1
                else:  # 'cmd': code inside "$( ... )"
                    if c == '\\' and j + 1 < L:
                        buf += 'xx'
                        j += 2
                        continue
                    if c in ('"', "'"):
                        stack.append([c])
                    elif c == '(':
                        top[1] += 1
                    elif c == ')':
                        top[1] -= 1
                        if top[1] == 0:
                            stack.pop()
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
            if c == "'" or c == '"':
                stack.append([c])
                qline = lineno
                buf += c
                j += 1
                continue
            if c == '$' and ln[j + 1:j + 2] == "'":
                stack.append(["$'"])
                qline = lineno
                buf += "$'"
                j += 2
                continue
            if c == '#' and (not buf or buf[-1] in ' \t;&|('):
                break
            if c == '<' and ln[j:j + 3] == '<<<':
                buf += '<<<'
                j += 3
                continue
            if c == '<' and ln[j:j + 2] == '<<' and not in_arith(buf):
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
        if stack or cont:
            cur += ' '
        if not stack and pending:
            for d, strip, hline in pending:
                while True:
                    if i >= n:
                        raise ParseError('%s:%d: unterminated heredoc %r (no closing delimiter)' % (path, hline, d))
                    body = lines[i]
                    i += 1
                    if (body.lstrip('\t') if strip else body) == d:
                        break
            pending = []
        if not stack and not cont:
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
    if stack:
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


KEYWORD = re.compile(r'(?:[a-z]+|\})(?=[\s;&|)]|$)')
IN_WORD = re.compile(r'\sin(?=[\s;]|$)')
TERMS = {'then', 'elif', 'else', 'fi', 'do', 'done', 'esac', '}'}
COMPOUNDS = {'if', 'while', 'until', 'for', 'select', 'case'}


class Item:
    def __init__(self, kind, text='', lists=()):
        self.kind = kind          # simple | subshell | group | compound
        self.text = text
        self.lists = list(lists)  # nested command lists (each a list of chains)
        self.bang = False
        self.line = 0


class Parser:
    """Recursive-descent parse of one test or function body (masked text).

    A chain is (items, ops): commands joined by && or ||. A list is a list of
    chains. Unknown or unbalanced input is tolerated: it never raises.
    """

    def __init__(self, text):
        self.t = text
        self.i = 0
        self.n = len(text)

    def ws(self, nl=False):
        while self.i < self.n and (self.t[self.i] in ' \t' or (nl and self.t[self.i] == '\n')):
            self.i += 1

    def word(self):
        m = KEYWORD.match(self.t, self.i)
        return m.group() if m else None

    def seps(self):
        while self.i < self.n and self.t[self.i] in ' \t\n;' and not self.t.startswith((';;', ';&'), self.i):
            self.i += 1

    def expect(self, w):
        self.seps()
        if self.word() == w:
            self.i += len(w)

    def body(self):
        chains = []
        while True:
            chains.extend(self.lst())
            if self.i >= self.n:
                return chains
            if self.t.startswith((';;', ';&'), self.i):
                self.i += 2
            elif self.t[self.i] == ')':
                self.i += 1
            else:
                self.i += max(len(self.word() or ''), 1)

    def lst(self):
        chains = []
        while True:
            self.seps()
            if self.i >= self.n or self.t.startswith((';;', ';&'), self.i) or self.t[self.i] == ')':
                break
            if self.word() in TERMS:
                break
            start = self.i
            chains.append(self.chain())
            if self.i == start:
                self.i += 1
        return chains

    def chain(self):
        items, ops = [], []
        while True:
            items.append(self.item())
            self.ws()
            if self.t.startswith(('&&', '||'), self.i):
                ops.append(self.t[self.i:self.i + 2])
                self.i += 2
                self.ws(nl=True)
                continue
            return items, ops

    def item(self):
        self.ws()
        start = self.i
        bang = False
        if self.t[self.i:self.i + 1] == '!' and (self.i + 1 >= self.n or self.t[self.i + 1] in ' \t\n'):
            bang = True
            self.i += 1
            self.ws()
        it = self.command()
        it.bang = bang
        it.start = start
        return it

    def simple(self):
        start = self.i
        depth = 0
        t = self.t
        while self.i < self.n:
            c = t[self.i]
            if c in '\n;' or t.startswith(('&&', '||'), self.i):
                break
            if c == '(':
                depth += 1
            elif c == ')':
                if depth == 0:
                    break
                depth -= 1
            self.i += 1
        return Item('simple', t[start:self.i].strip())

    def command(self):
        t = self.t
        c = t[self.i:self.i + 1]
        if c == '(' and t[self.i + 1:self.i + 2] != '(':
            self.i += 1
            lst = self.lst()
            self.ws(nl=True)
            if t[self.i:self.i + 1] == ')':
                self.i += 1
            return Item('subshell', lists=[lst])
        if c == '{' and (self.i + 1 >= self.n or t[self.i + 1] in ' \t\n'):
            self.i += 1
            lst = self.lst()
            self.expect('}')
            return Item('group', lists=[lst])
        w = self.word()
        if w not in COMPOUNDS:
            return self.simple()
        self.i += len(w)
        if w == 'if':
            self.lst()
            self.expect('then')
            lists = [self.lst()]
            while True:
                self.seps()
                k = self.word()
                if k == 'elif':
                    self.i += 4
                    self.lst()
                    self.expect('then')
                    lists.append(self.lst())
                elif k == 'else':
                    self.i += 4
                    lists.append(self.lst())
                else:
                    break
            self.expect('fi')
            return Item('compound', lists=lists)
        if w in ('while', 'until'):
            self.lst()
            self.expect('do')
        elif w in ('for', 'select'):
            self.simple()
            self.expect('do')
        else:  # case
            m = IN_WORD.search(t, self.i)
            if m:
                self.i = m.end()
            else:
                self.simple()
            lists = []
            while True:
                before = self.i
                self.seps()
                if self.i >= self.n:
                    break
                if self.word() == 'esac':
                    self.i += 4
                    break
                j = t.find(')', self.i)
                if j < 0:
                    self.i = self.n
                    break
                self.i = j + 1
                lists.append(self.lst())
                if t.startswith((';;&', ';;'), self.i):
                    self.i += 3 if t.startswith(';;&', self.i) else 2
                elif t.startswith(';&', self.i):
                    self.i += 2
                elif t[self.i:self.i + 1] == ')':
                    self.i += 1
                if self.i == before:
                    self.i += 1
            return Item('compound', lists=lists)
        lists = [self.lst()]
        self.expect('done')
        return Item('compound', lists=lists)


def is_false(it):
    return it.kind == 'simple' and not it.bang and it.text == 'false'


def check_list(chains, tail, line_of, found):
    """tail: this list's last status becomes the status of the enclosing
    errexit-checked region (the test, function or subshell body)."""
    for ci, (items, ops) in enumerate(chains):
        tc = tail and ci == len(chains) - 1
        for k, it in enumerate(items):
            used = tc and all(o == '&&' for o in ops[k:])
            if it.bang:
                nxt = ops[k] if k < len(ops) else None
                if nxt == '||':
                    # `! x || false` fails the test unless something follows
                    # the false: `|| ...` never; `&& ...` only as the last command.
                    after = ops[k + 1] if k + 1 < len(ops) else None
                    if is_false(items[k + 1]):
                        ok = after is None or (after == '&&' and tc and all(o == '&&' for o in ops[k + 1:]))
                    else:
                        ok = False
                else:
                    ok = used
                if not ok:
                    found.append(line_of(it.start))
            if it.kind == 'subshell':
                # A failing subshell trips errexit itself, so its last
                # command counts whenever the subshell is not rescued.
                inner = k == len(items) - 1 or used
            else:
                inner = used and not it.bang
            for lst in it.lists:
                check_list(lst, inner, line_of, found)


def check_body(body):
    """body: [(masked_text, marks)] of one test or function. Return finding lines."""
    text = ''
    allmarks = []
    for btext, bmarks in body:
        allmarks.extend((len(text) + o, ln) for o, ln in bmarks)
        text += mask_nested(btext) + '\n'
    offsets = [m[0] for m in allmarks]

    def line_of(off):
        return allmarks[max(bisect.bisect_right(offsets, off) - 1, 0)][1]

    found = []
    check_list(Parser(text).body(), True, line_of, found)
    return found


NAME = r'[A-Za-z_][\w:.-]*'
TEST_HEAD = re.compile(r'@test\s+(?:"[^"]*"|\'[^\']*\'|\S+)\s*\{(.*)$')
FUNC_HEAD = re.compile(r'(?:function\s+%s(?:\s*\(\))?|%s\s*\(\))\s*\{(.*)$' % (NAME, NAME))
FUNC_NAME = re.compile(r'(?:function\s+%s(?:\s*\(\))?|%s\s*\(\))\s*$' % (NAME, NAME))
BRACE_NEXT = re.compile(r'\{(?:\s(.*))?$')
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
        rest = None
        if m:
            rest = m.group(1)
        elif col0 and FUNC_NAME.match(s) and i + 1 < N and ll[i + 1][2]:
            # `name()` or `function name` with the `{` alone on the next line.
            nb = BRACE_NEXT.match(ll[i + 1][0].strip())
            if nb:
                rest = nb.group(1) or ''
                i += 1
        if rest is None:
            i += 1
            continue
        hline = marks[0][1]
        kind = 'test' if s.startswith('@test') else 'function'
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
        findings.extend(check_body(body))
    return findings


def main(argv):
    files = argv
    if not files:
        files = sorted(set(glob.glob('tests/*.bats') + glob.glob('tests/*/*.bats')))
        if not files:
            print('bats-negation: no tests/*.bats or tests/*/*.bats files found '
                  'under %s (run from the repo root)' % os.getcwd(), file=sys.stderr)
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
