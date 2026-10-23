# The format of a design note's precedent lines (CCW-157 AC 2; the designer
# emits the same lines, CCW-158). One definition, used by the bats tests.
#
# A design text is valid when:
#   - exactly one line begins "Precedent: ", and it matches
#       ^Precedent: (none declared|[^ ]+ \| ".+")$
#   - every line that begins "checked: " matches
#       ^checked: .+ \| .+ \| .+$
# Lines that begin "> " are quotes and are never read as either.
#
# design_format_ok <file>: exit 0 when valid; else print a message naming the
# line (or the count) on stdout and exit 1.
design_format_ok() {
  local file=$1 line n=0 num=0
  local precedent_re='^Precedent: (none declared|[^ ]+ \| ".+")$'
  local checked_re='^checked: .+ \| .+ \| .+$'
  [ -f "$file" ] || { echo "no such file: $file"; return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    num=$((num + 1))
    case $line in
      "Precedent: "*)
        n=$((n + 1))
        if ! [[ $line =~ $precedent_re ]]; then
          echo "line $num: bad Precedent line: $line"
          return 1
        fi
        ;;
      "checked: "*)
        if ! [[ $line =~ $checked_re ]]; then
          echo "line $num: bad checked line: $line"
          return 1
        fi
        ;;
    esac
  done <"$file"
  if [ "$n" -ne 1 ]; then
    echo "expected exactly one Precedent line, found $n"
    return 1
  fi
  return 0
}
