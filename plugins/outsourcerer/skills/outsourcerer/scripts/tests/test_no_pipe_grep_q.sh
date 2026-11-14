#!/usr/bin/env bash
# Quiet grep can close a pipe early and make its producer fail under pipefail.
set -uo pipefail
if ! command -v python3 >/dev/null 2>&1; then
  printf "SKIP: python3 is required for the quiet-grep guard\n"
  exit 0
fi
HERE="$(cd "$(dirname "$0")" && pwd)"
python3 - "${1:-$HERE}" <<'PY'
import pathlib,re,shlex,sys
root=pathlib.Path(sys.argv[1])

def uncomment(line):
    single=double=False; i=0
    while i<len(line):
        c=line[i]
        if c=='\\' and not single: i+=2; continue
        if c=="'" and not double: single=not single
        elif c=='"' and not single: double=not double
        elif c=='#' and not single and not double and (i==0 or line[i-1].isspace()): return line[:i]
        i+=1
    return line

def heredocs(line):
    result=[]; single=double=False; i=0
    while i<len(line):
        c=line[i]
        if c=='\\' and not single: i+=2; continue
        if c=="'" and not double: single=not single
        elif c=='"' and not single: double=not double
        elif not single and not double and line[i:i+2]=='<<' and line[i:i+3]!='<<<' and (i==0 or line[i-1]!='<'):
            m=re.match(r"<<(-?)[ \t]*(?:(['\"])([^'\"\n]+)\2|\\([A-Za-z_][A-Za-z0-9_-]*)|([A-Za-z_][A-Za-z0-9_-]*))",line[i:])
            if m:
                result.append((m.group(3) or m.group(4) or m.group(5),bool(m.group(1))))
                i+=m.end(); continue
        i+=1
    return result

def tokens(line):
    lex=shlex.shlex(line,posix=True,punctuation_chars='|&;()<>')
    lex.whitespace_split=True; lex.commenters=''
    result=[]
    try:
        while True:
            token=lex.get_token()
            if token is None: break
            result.append(token)
    except ValueError: pass
    return result

def is_quiet_grep(cmd):
    i=0
    while i<len(cmd) and re.match(r'^[A-Za-z_][A-Za-z_0-9]*=',cmd[i]): i+=1
    if i<len(cmd) and cmd[i]=='env':
        i+=1
        while i<len(cmd):
            if cmd[i] in ('-u','--unset','-C','--chdir'):
                i+=2; continue
            if cmd[i]=='--': i+=1; break
            if cmd[i].startswith('-') or re.match(r'^[A-Za-z_][A-Za-z_0-9]*=',cmd[i]):
                i+=1; continue
            break
    if i<len(cmd) and cmd[i]=='command':
        i+=1
        while i<len(cmd) and cmd[i].startswith('-'): i+=1
    if i>=len(cmd) or pathlib.PurePosixPath(cmd[i]).name not in ('grep','egrep','fgrep'): return False
    i+=1
    while i<len(cmd):
        x=cmd[i]
        if x=='--': return False
        if x in ('-e','-f','--regexp','--file'): i+=2; continue
        if x in ('--quiet','--silent') or (x.startswith('-') and not x.startswith('--') and 'q' in x[1:]): return True
        i+=1
    return False

def substitutions(line):
    single=double=False; i=0
    while i<len(line):
        c=line[i]
        if c=='\\' and not single: i+=2; continue
        if c=="'" and not double: single=not single; i+=1; continue
        if c=='"' and not single: double=not double; i+=1; continue
        if not single and line[i:i+2]=='$(' and line[i:i+3]!='$((':
            start=i+2; j=start; depth=1; inner_single=inner_double=False
            while j<len(line) and depth:
                ch=line[j]
                if ch=='\\' and not inner_single: j+=2; continue
                if ch=="'" and not inner_double: inner_single=not inner_single
                elif ch=='"' and not inner_single: inner_double=not inner_double
                elif not inner_single and not inner_double:
                    if ch=='(': depth+=1
                    elif ch==')': depth-=1
                j+=1
            if depth==0:
                yield line[start:j-1]
                i=j; continue
        i+=1

def scan(line,depth=0):
    if depth>6:return False
    ts=tokens(line)
    # check/eval execute their argument as shell, unlike plain quoted messages.
    if ts and ts[0]=='check' and len(ts)>2:
        if '|' in ts[2] and scan(ts[2],depth+1): return True
    if ts and ts[0]=='eval':
        code=' '.join(ts[1:])
        if '|' in code and scan(code,depth+1): return True
    commands=[]; current=[]; operators=[]
    for t in ts:
        if t in ('|','|&','||','&&',';','(',')','&'):
            if current: commands.append(current); current=[]
            else: commands.append([])
            operators.append(t)
        else: current.append(t)
    commands.append(current)
    for i,op in enumerate(operators):
        if op not in ('|','|&'): continue
        j=i+1
        while j<len(commands):
            if is_quiet_grep(commands[j]): return True
            if j>=len(operators) or operators[j] not in ('|','|&'): break
            j+=1
    # Command substitutions execute inside double quotes but not single quotes.
    for part in substitutions(line):
        if '|' in part and scan(part,depth+1): return True
    return False

def logical_lines(text):
    queued=[]; pending=''; start=0
    for n,raw in enumerate(text.splitlines(),1):
        if queued:
            delim,strip=queued[0]
            if (raw.lstrip('\t') if strip else raw)==delim: queued.pop(0)
            continue
        line=uncomment(raw)
        if not pending: start=n
        pending+=line
        if pending.rstrip().endswith('\\'):
            pending=pending.rstrip()[:-1]+' '; continue
        if pending.rstrip().endswith('|') and not pending.rstrip().endswith('||'):
            pending+=' '; continue
        queued.extend(heredocs(pending))
        yield start,pending
        pending=''
    if pending: yield start,pending

failed=False
for path in sorted(root.rglob('*.sh')):
    lines=list(logical_lines(path.read_text()))
    if not any(re.search(r'(?:^|[;&])\s*(?:set|shopt)\s+[^\n#]*\bpipefail\b',s) for _,s in lines): continue
    for number,line in lines:
        if scan(line): print(f'{path}:{number}: producer piped into quiet grep'); failed=True
if failed: sys.exit(1)
print('PASS: no producer pipe into quiet grep in pipefail tests')
PY
